#!/bin/ash
# EclipVPN — server management: select / probe / update / ping / auto-select+eval.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers, all
# resolved at call time, so source order among the libs does not matter.

# Cheap reachability RTT in ms (stdout), or -1 when unreachable. Single attempt
# — the auto paths probe the real tunnel on the winner anyway. xray protocols
# are TCP, so a TLS connect to :443 measures handshake RTT. hysteria2 is QUIC
# (UDP) with NO TCP listener on :443, so a TCP connect always fails; fall back
# to ICMP for those. An ICMP-blocked hysteria2 host returns -1 and is skipped by
# the cheap pre-filter (auto-select/auto-eval) — it can still be chosen manually
# (which probes the real tunnel), and the watchdog failover scan probes every
# candidate directly (not via this filter), so failover still reaches it.
_reach_ms() {
    local host="$1" proto="$2" t icmp
    if [ "$proto" != "hysteria2" ]; then
        t=$(curl -s -o /dev/null --max-time 3 --connect-timeout 3 -w '%{time_connect}' "https://$host:443" 2>/dev/null)
        if [ -n "$t" ] && [ "$t" != "0.000000" ]; then
            echo "$t" | awk '{printf "%d", $1 * 1000}'
            return
        fi
    fi
    icmp=$(ping -c 1 -W 2 "$host" 2>/dev/null | awk -F'time=' '/time=/{split($2,a," "); print int(a[1]+0.5); exit}')
    if [ -n "$icmp" ] && [ "$icmp" -gt 0 ] 2>/dev/null; then echo "$icmp"; else echo -1; fi
}

# ============================================================
# Server management
# ============================================================

cmd_set_server() {
    local idx="$1"
    [ -z "$idx" ] && { _err "missing server index"; return 1; }
    # Numeric, non-negative only: the >= total check below is upper-bound only,
    # so "-1" would pass it and jq .[-1] resolves to the LAST server.
    case "$idx" in *[!0-9]*) _err "invalid server index"; return 1 ;; esac
    flog "Setting server to index $idx"
    [ -f "$ECLIPVPN_TMP/servers.json" ] || { _err "no servers (run update first)"; return 1; }
    local total=$(jq 'length' "$ECLIPVPN_TMP/servers.json")
    [ "$idx" -ge "$total" ] 2>/dev/null && { _err "invalid server index"; return 1; }
    local old_sel; old_sel=$(get_config_val selected_server 0)
    update_config '.selected_server = $idx' --argjson idx "$idx" || { _err "config save failed"; return 1; }
    # _vpn_live, not _vpn_running: selected_server was JUST changed above, so an
    # engine-aware check would read the NEW server's engine (e.g. xray) while the
    # OLD tunnel's daemons (e.g. Hysteria2 sing-box) are what's actually live —
    # that false-negative would silently skip the switch.
    if _vpn_live; then
        cmd_restart
        local _rc=$?
        # make-before-break can REJECT the switch (new server unreachable) and
        # keep the OLD tunnel up. Roll selected_server back so status/UI don't
        # show a server we're not actually on.
        [ "$_rc" -ne 0 ] && update_config '.selected_server = $old' --argjson old "$old_sel" >/dev/null 2>&1
        return "$_rc"
    else
        local name=$(jq -r ".[$idx].name" "$ECLIPVPN_TMP/servers.json")
        jq -n --arg srv "$name" '{status:"server set",server:$srv}'
    fi
}

# Pre-flight: spin up a temp xray bound to an unused port and verify the
# target server actually answers, before we tear down the running VPN.
# Returns: {"status":"ok","ip":"...","latency_ms":N} on success
#          {"error":"..."} on failure (production xray/sing-box untouched)
cmd_probe_server() {
    local idx="$1"
    [ -z "$idx" ] && { _err "missing server index"; return 1; }
    # Numeric, non-negative only — the >= total check is upper-bound only and
    # jq .[-1] would resolve a negative index to the last server.
    case "$idx" in *[!0-9]*) _err "invalid server index"; return 1 ;; esac
    [ -f "$ECLIPVPN_TMP/servers.json" ] || { _err "no servers (run update first)"; return 1; }
    local total
    total=$(jq 'length' "$ECLIPVPN_TMP/servers.json")
    [ "$idx" -ge "$total" ] 2>/dev/null && { _err "invalid server index"; return 1; }
    # Engine-aware: hysteria2 probes spawn a throwaway sing-box dialer, the rest
    # a throwaway xray — require the matching binary before spending time.
    local p_eng
    p_eng=$(_engine_for_protocol "$(_server_protocol "$idx")")
    if [ "$p_eng" = "singbox" ]; then
        [ -x /usr/bin/sing-box ] || { echo '{"error":"sing-box binary missing"}'; return 1; }
    else
        [ -x /usr/bin/xray ] || { echo '{"error":"xray binary missing"}'; return 1; }
    fi
    mkdir -p "$ECLIPVPN_TMP"

    # Run the actual probe in a subshell. In ash `trap EXIT` is process-wide,
    # not function-scoped — running this body as a function inside e.g. the
    # watchdog process would clobber the watchdog's own EXIT trap (which
    # cleans up watchdog.lock). Subshell isolates the trap to the probe.
    (
        # Unique filename so a probe and a concurrent watchdog failover don't
        # overwrite each other's configs. Need a .json suffix because xray
        # sniffs format from filename; busybox mktemp can't add a suffix, so
        # mktemp → rename. _gen_probe_config builds the right engine's config.
        local _p probe_cfg
        _p=$(mktemp "$ECLIPVPN_TMP/probe.XXXXXX") || exit 1
        probe_cfg="${_p}.json"; mv "$_p" "$probe_cfg"
        local probe_pid=""
        trap 'kill $probe_pid 2>/dev/null; wait $probe_pid 2>/dev/null; rm -f "$probe_cfg" "${probe_cfg}.base"' EXIT INT TERM

        local probe_port=$((1082 + $$ % 100))
        # Build the throwaway probe config; eng tells us which binary to spawn.
        local eng
        eng=$(_gen_probe_config "$idx" "$probe_port" "$probe_cfg") || { echo '{"error":"failed to generate probe config"}'; exit 1; }
        [ -s "$probe_cfg" ] || { echo '{"error":"failed to generate probe config"}'; exit 1; }

        # Up to 4 spawn-and-test attempts. A freshly-spawned xray's very
        # first request through VLESS+XHTTP+Reality occasionally hangs to
        # full timeout (measured ~50% on DE/NL endpoints when probing while
        # prod xray is connected to a different server — likely cold xmux
        # state on the remote). Once a probe xray hits this, retrying *its*
        # curl doesn't recover; only respawning xray does. The user-visible
        # symptom was "не получается переключиться с первого раза" — the
        # picker click triggered a flaky probe, toast said "Не удалось
        # переключить", and the immediate second click succeeded.
        # 4 attempts × ~16s worst-case (6s listen wait + 10s curl) ≤ 64s,
        # but typical success on attempt 1-2 keeps real wall-clock <20s.
        # The 10s curl budget (was 6s) covers the cold Reality+XHTTP
        # handshake on DE/NL endpoints — 6s was tripping on live servers
        # that ping fine but need >6s on first request. An outright dead
        # server is detected on attempt 1 because curl returns immediately
        # (port unreachable) — this loop only burns time on flakes.
        local t0 t1 elapsed test_ip="" attempt
        t0=$(date +%s%3N 2>/dev/null)
        for attempt in 1 2 3 4; do
            # Spawn a fresh engine for each attempt — reusing a hung instance
            # doesn't help (its outbound state is broken).
            [ -n "$probe_pid" ] && {
                kill "$probe_pid" 2>/dev/null
                wait "$probe_pid" 2>/dev/null
                probe_pid=""
            }
            if [ "$eng" = "singbox" ]; then
                /usr/bin/sing-box run -c "$probe_cfg" -D "$ECLIPVPN_TMP" >/dev/null 2>&1 &
            else
                /usr/bin/xray run -config "$probe_cfg" >/dev/null 2>&1 &
            fi
            probe_pid=$!

            # Wait for the SOCKS inbound to actually listen before curl-ing.
            # busybox sleep doesn't accept fractional seconds, so this is
            # 1s granularity, capped at 6s.
            local ready=0 wait_i=0
            while [ "$wait_i" -lt 6 ]; do
                kill -0 "$probe_pid" 2>/dev/null || break
                if netstat -tlnp 2>/dev/null | grep -q ":$probe_port "; then
                    ready=1
                    break
                fi
                sleep 1
                wait_i=$((wait_i + 1))
            done
            [ "$ready" -eq 0 ] && continue

            test_ip=$(curl -s --socks5-hostname "127.0.0.1:$probe_port" --max-time 10 https://api.ipify.org 2>/dev/null)
            [ -n "$test_ip" ] && break
        done
        t1=$(date +%s%3N 2>/dev/null)
        # Fallback: if busybox date doesn't support %3N, both are non-numeric.
        case "$t0$t1" in *[!0-9]*) elapsed=0;; *) elapsed=$((t1 - t0));; esac
        [ "$elapsed" -lt 0 ] 2>/dev/null && elapsed=0

        if [ -n "$test_ip" ]; then
            local name
            name=$(jq -r --argjson i "$idx" '.[$i].name // ""' "$ECLIPVPN_TMP/servers.json")
            jq -n --arg ip "$test_ip" --arg name "$name" --argjson ms "$elapsed" \
                '{status:"ok", ip:$ip, server:$name, latency_ms:$ms}'
            exit 0
        else
            echo '{"error":"server unreachable"}'
            exit 1
        fi
    )
}

cmd_update() {
    # Capture previous server count so the UI can detect whether this run
    # actually changed anything (cron auto-update fires every N hours and
    # most of the time returns the same list — we don't want to spam toasts).
    local prev=0
    [ -f "$ECLIPVPN_TMP/servers.json" ] && prev=$(jq 'length' "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
    [ -z "$prev" ] && prev=0

    local count
    count=$(update_subscription "$ECLIPVPN_CONFIG")
    local mode=$(get_config_val mode "all_vpn")
    # Fetch-then-swap (refresh_rules): the old `rm -rf rules` + refetch left
    # blocklist mode ruleless when the refetch failed — e.g. an offline
    # nightly cron run — and the next restart sent everything direct.
    refresh_rules "$mode" || flog "WARN: rule refresh failed — keeping previous lists"
    # Periodic refresh of sing-box .srs rule sets — cmd_update is the
    # natural moment to redownload upstream geosite/geoip without paying
    # the cost on every cmd_start. Failure leaves the cached copy in
    # place; logs note the warning but cmd_update doesn't fail on it.
    _fetch_rule_sets force || true
    if [ "$count" -gt 0 ] 2>/dev/null; then
        # Record the run for the UI's status polling — last_update lets the
        # frontend show a toast only when prev != count (avoids "updated:
        # same 7 servers" noise on cron-driven refresh).
        jq -n --argjson t "$(date +%s)" --argjson c "$count" --argjson p "$prev" \
            '{time:$t, count:$c, prev_count:$p}' > "$ECLIPVPN_TMP/last_update.json"
        echo "{\"status\":\"updated\",\"servers\":$count,\"prev\":$prev}"
        _sync_zapret_exclude
        _vpn_running && cmd_restart >/dev/null
    else
        echo '{"error":"update failed"}'
        return 1
    fi
}

cmd_ping() {
    [ -f "$ECLIPVPN_TMP/servers.json" ] || { _err "no servers (run update first)"; return 1; }
    local total=$(jq 'length' "$ECLIPVPN_TMP/servers.json")
    local tmpdir=$(mktemp -d "$ECLIPVPN_TMP/ping.XXXXXX")

    # Per-server probe runs in parallel. Small pool: 3 attempts × 3s TCP-connect,
    # take the minimum (v2rayN-style; ~20% TCP-RST flap on one upstream needed 3×
    # to drop false-negatives <1%), plus an ICMP fallback (some providers RST :443
    # bursts but answer ICMP). BIG pool (>40 servers, multi-subscription): a 177-
    # server sweep at 3 attempts took ~52s and never reached the UI — uhttpd kills
    # the CGI at network_timeout=30s, and the browser fetch times out earlier — so
    # for big pools do ONE 2s attempt and skip the per-server ICMP fallback (except
    # hysteria2, which has no TCP listener), landing well under the timeout.
    local fast=0; [ "$total" -gt 40 ] 2>/dev/null && fast=1
    local i=0
    while [ "$i" -lt "$total" ]; do
        local host=$(jq -r ".[$i].host" "$ECLIPVPN_TMP/servers.json")
        local proto=$(jq -r ".[$i].protocol // \"vless\"" "$ECLIPVPN_TMP/servers.json")
        local out="$tmpdir/$i"
        (
            best=-1
            # hysteria2 is QUIC (UDP) — a TCP connect to :443 always fails, so
            # skip straight to ICMP for it (saves 3×3s of dead TCP probing).
            if [ "$proto" != "hysteria2" ]; then
                _att=3; _ct=3
                [ "$fast" = "1" ] && { _att=1; _ct=2; }
                _n=0
                while [ "$_n" -lt "$_att" ]; do
                    _n=$((_n + 1))
                    t=$(curl -s -o /dev/null --max-time "$_ct" --connect-timeout "$_ct" -w '%{time_connect}' "https://$host:443" 2>/dev/null)
                    if [ -n "$t" ] && [ "$t" != "0.000000" ]; then
                        ms=$(echo "$t" | awk '{printf "%d", $1 * 1000}')
                        if [ "$best" -lt 0 ] || [ "$ms" -lt "$best" ]; then best=$ms; fi
                    fi
                done
            fi
            # ICMP fallback (single packet, 2s): always for hysteria2 (no TCP);
            # for TCP only in a small pool — in a big pool the extra 2s per down
            # server would blow the time budget (down → -1 immediately instead).
            if [ "$best" -lt 0 ] && { [ "$proto" = "hysteria2" ] || [ "$fast" != "1" ]; }; then
                icmp=$(ping -c 1 -W 2 "$host" 2>/dev/null | awk -F'time=' '/time=/{split($2,a," "); print int(a[1]+0.5); exit}')
                [ -n "$icmp" ] && [ "$icmp" -gt 0 ] 2>/dev/null && best=$icmp
            fi
            echo "$best" > "$out"
        ) &
        i=$((i + 1))
    done
    wait

    local results="[]"
    i=0
    while [ "$i" -lt "$total" ]; do
        local name=$(jq -r ".[$i].name" "$ECLIPVPN_TMP/servers.json")
        local ms=$(cat "$tmpdir/$i" 2>/dev/null)
        [ -z "$ms" ] && ms=-1
        results=$(echo "$results" | jq --arg n "$name" --argjson ms "$ms" --argjson i "$i" '. + [{name:$n, ping:$ms, index:$i}]')
        i=$((i + 1))
    done
    rm -rf "$tmpdir"
    echo "$results" | jq '.'
}

# Find the lowest-RTT non-metered server and switch to it. Used by the
# "Auto" button — picks a sensible default for the user without making
# them squint at numbers. Skips metered (МТС/Т2/etc) since they hand back
# Russian IPs and would defeat the VPN.
#
# Two-stage selection: TCP RTT to filter candidates fast, then real VLESS
# probe on the winner. Without the probe, we'd happily pick a server whose
# port answers TCP but whose Reality keys have rotated — UI would say
# "switched" while VPN is broken. With it, we either confirm the switch
# really worked or report failure honestly.
# Helper to append an attempt entry to the running list. Used purely to
# keep the auto_select function readable.
_attempt_add() {
    # $1 = jq array string, $2 = name, $3 = idx, $4 = rtt (or -1), $5 = status
    echo "$1" | jq --arg n "$2" --argjson i "$3" --argjson ms "$4" --arg s "$5" \
        '. + [{name:$n, index:$i, rtt_ms:(if $ms < 0 then null else $ms end), status:$s}]'
}

cmd_auto_select() {
    [ -f "$ECLIPVPN_TMP/servers.json" ] || { _err "no servers (run update first)"; return 1; }
    local total i=0 name host ms
    total=$(jq 'length' "$ECLIPVPN_TMP/servers.json")

    # attempts collects an ordered audit trail of every server we considered:
    # what status (skipped_metered / skipped_muted / unreachable / probe_failed /
    # selected / already_active) and its RTT. This is what powers the "why X and
    # not Y" explanation in the UI toast.
    local attempts="[]"
    local candidates=""
    local muted; muted=$(_muted_tokens)
    local emergency=false
    while [ "$i" -lt "$total" ]; do
        name=$(jq -r ".[$i].name" "$ECLIPVPN_TMP/servers.json")
        host=$(jq -r ".[$i].host" "$ECLIPVPN_TMP/servers.json")
        if _is_metered_server "$name"; then
            attempts=$(_attempt_add "$attempts" "$name" "$i" -1 "skipped_metered")
        elif _name_has_token "$name" "$muted"; then
            attempts=$(_attempt_add "$attempts" "$name" "$i" -1 "skipped_muted")
        else
            ms=$(_reach_ms "$host" "$(_server_protocol "$i")")
            if [ "$ms" -gt 0 ] 2>/dev/null; then
                candidates="$candidates$ms $i\n"
            else
                attempts=$(_attempt_add "$attempts" "$name" "$i" -1 "unreachable")
            fi
        fi
        i=$((i + 1))
    done

    # Emergency pass: nothing un-muted answered, so lift the mute rather than
    # leave the user with no exit at all. Metered stays excluded (a Russian IP
    # is not a working VPN — see _is_auto_skipped). The `emergency` flag rides
    # out in the response so the UI can say WHY a muted server was picked.
    if [ -z "$candidates" ] && [ -n "$muted" ]; then
        flog "Auto-select: no un-muted server answered — retrying muted ones"
        i=0
        while [ "$i" -lt "$total" ]; do
            name=$(jq -r ".[$i].name" "$ECLIPVPN_TMP/servers.json")
            host=$(jq -r ".[$i].host" "$ECLIPVPN_TMP/servers.json")
            if ! _is_metered_server "$name" && _name_has_token "$name" "$muted"; then
                ms=$(_reach_ms "$host" "$(_server_protocol "$i")")
                if [ "$ms" -gt 0 ] 2>/dev/null; then
                    candidates="$candidates$ms $i\n"
                    emergency=true
                fi
            fi
            i=$((i + 1))
        done
        [ "$emergency" = true ] && \
            _log_incident "emergency_muted" "" "" "ни один не-замьюченный сервер не ответил — выбираем из замьюченных (тарифицируемых)"
    fi

    if [ -z "$candidates" ]; then
        jq -n --argjson att "$attempts" '{error:"no reachable servers", attempts:$att}'
        return 1
    fi
    local sorted
    sorted=$(printf '%b' "$candidates" | sort -n)

    local cur best_idx best_ms best_name
    cur=$(get_config_val selected_server 0)

    while IFS=' ' read -r ms idx; do
        [ -z "$idx" ] && continue
        name=$(jq -r --argjson i "$idx" '.[$i].name' "$ECLIPVPN_TMP/servers.json")
        if [ "$idx" = "$cur" ] && _vpn_running && [ -n "$(test_xray "$(_active_socks_port)")" ]; then
            attempts=$(_attempt_add "$attempts" "$name" "$idx" "$ms" "already_active")
            jq -n --arg n "$name" --argjson i "$idx" --argjson ms "$ms" --argjson att "$attempts" --argjson em "$emergency" \
                '{status:"ok", server:$n, index:$i, rtt_ms:$ms, switched:false, emergency:$em, attempts:$att}'
            return 0
        fi
        flog "Auto-select: probing $name (idx=$idx rtt=${ms}ms)"
        local probe
        probe=$(cmd_probe_server "$idx" 2>/dev/null)
        if echo "$probe" | jq -e '.status == "ok"' >/dev/null 2>&1; then
            attempts=$(_attempt_add "$attempts" "$name" "$idx" "$ms" "selected")
            best_idx="$idx"; best_ms="$ms"; best_name="$name"
            break
        fi
        attempts=$(_attempt_add "$attempts" "$name" "$idx" "$ms" "probe_failed")
        flog "Auto-select: $name failed VLESS probe — trying next"
    done <<EOF
$sorted
EOF

    if [ -z "$best_idx" ]; then
        jq -n --argjson att "$attempts" '{error:"no working servers (all failed VLESS probe)", attempts:$att}'
        return 1
    fi

    flog "Auto-select: chose $best_name idx=$best_idx rtt=${best_ms}ms"
    if [ "$cur" = "$best_idx" ]; then
        jq -n --arg n "$best_name" --argjson i "$best_idx" --argjson ms "$best_ms" --argjson att "$attempts" --argjson em "$emergency" \
            '{status:"ok", server:$n, index:$i, rtt_ms:$ms, switched:false, emergency:$em, attempts:$att}'
        return 0
    fi

    # Whole switch + state stamp under one op-lock — prevents watchdog
    # auto_eval racing on config and auto_state. Subshell exit code:
    # 0 = ok, 1 = lock contention, 2 = cmd_restart failure (rolled back).
    mkdir -p "$ECLIPVPN_TMP"
    local sf="$ECLIPVPN_TMP/auto_state.json"
    local oplock="$ECLIPVPN_TMP/auto.lock"
    (
        if command -v flock >/dev/null 2>&1; then flock -w 5 -x 9 || exit 1; fi
        update_config '.selected_server = $idx' --argjson idx "$best_idx"
        # _vpn_live, not _vpn_running — see cmd_set_server: selected_server was
        # just changed, so an engine-aware check could miss a live other-engine
        # tunnel and skip the switch.
        if _vpn_live; then
            if ! ( cmd_restart ) >/dev/null 2>&1; then
                update_config '.selected_server = $idx' --argjson idx "$cur"
                # Subshell: the first cmd_restart's op-lock is only released when
                # ITS subshell exits (trap EXIT), so the rollback restart must run
                # in its own subshell or it self-deadlocks on op.lock.
                ( cmd_restart ) >/dev/null 2>&1
                exit 2
            fi
        fi
        [ -f "$sf" ] || printf '%s\n' '{"last_eval":0,"last_switch":0}' > "$sf"
        local now=$(date +%s)
        jq --argjson t "$now" '.last_eval = $t | .last_switch = $t' "$sf" > "${sf}.tmp" && mv "${sf}.tmp" "$sf"
    ) 9>"$oplock"
    local rc=$?
    case "$rc" in
        0) ;;
        1)
            jq -n --arg n "$best_name" --argjson att "$attempts" '{error:"another auto operation in progress", server:$n, attempts:$att}'
            return 1
            ;;
        2)
            flog "Auto-select: restart failed — rolled back to idx=$cur"
            jq -n --arg n "$best_name" --argjson att "$attempts" '{error:"restart failed", server:$n, attempts:$att}'
            return 1
            ;;
        *)
            jq -n --arg n "$best_name" --argjson att "$attempts" '{error:"unexpected", server:$n, attempts:$att}'
            return 1
            ;;
    esac

    jq -n --arg n "$best_name" --argjson i "$best_idx" --argjson ms "$best_ms" --argjson att "$attempts" --argjson em "$emergency" \
        '{status:"ok", server:$n, index:$i, rtt_ms:$ms, switched:true, emergency:$em, attempts:$att}'
}

# Periodic re-evaluation invoked by the watchdog. Honours hysteresis so we
# don't bounce between similar-RTT servers, and a cooldown so even when
# improvements appear we don't switch more than once per hour (unless the
# current tunnel is actually broken — then any working candidate is fine).
cmd_auto_eval() {
    [ -f "$ECLIPVPN_TMP/servers.json" ] || return 1
    _vpn_running || return 0   # not running → not our job, watchdog handles

    mkdir -p "$ECLIPVPN_TMP"
    local sf="$ECLIPVPN_TMP/auto_state.json"
    local oplock="$ECLIPVPN_TMP/auto.lock"

    # Whole eval runs under an op-level flock. -n (non-blocking) — if a
    # user-triggered cmd_auto_select is running, we silently skip this tick
    # rather than queue up a redundant eval behind it.
    (
        if command -v flock >/dev/null 2>&1; then flock -n -x 9 || { flog "Auto-eval: another auto op in progress, skipping"; exit 0; }; fi

        [ -f "$sf" ] || printf '%s\n' '{"last_eval":0,"last_switch":0}' > "$sf"

        local now last_eval last_switch
        now=$(date +%s)
        last_eval=$(jq -r '.last_eval // 0' "$sf")
        last_switch=$(jq -r '.last_switch // 0' "$sf")

        # Self-rate-limit: at most once per 20 min, even if watchdog calls more often.
        [ $((now - last_eval)) -lt 1200 ] && exit 0

        # Update last_eval up-front so a hung eval doesn't hold off the next one
        # forever; we'll write it again at the very end too.
        jq --argjson t "$now" '.last_eval = $t' "$sf" > "${sf}.tmp" && mv "${sf}.tmp" "$sf"

        # Is the current tunnel actually carrying traffic? (test_xray returns the
        # exit IP via the running socks; empty = dead tunnel.)
        local current_broken=0
        [ -z "$(test_xray "$(_active_socks_port)")" ] && current_broken=1

        # Cooldown: if current is fine and we switched < 1h ago, do nothing.
        if [ "$current_broken" -eq 0 ] && [ $((now - last_switch)) -lt 3600 ]; then
            exit 0
        fi

        # Measure RTT for all auto-eligible servers; remember current's RTT for
        # hysteresis. Auto-eligible = not metered and not user-muted.
        local total i=0 name host ms current_idx current_rtt=-1 candidates=""
        local muted; muted=$(_muted_tokens)
        total=$(jq 'length' "$ECLIPVPN_TMP/servers.json")
        current_idx=$(get_config_val selected_server 0)
        # Bounds-check: subscription may have shrunk while we were on a higher
        # index. Treat that as broken so we move to a real server.
        if [ "$current_idx" -ge "$total" ] 2>/dev/null; then
            flog "Auto-mode: current_idx=$current_idx out of range (total=$total) — treating as broken"
            current_broken=1
            current_idx=0
        fi
        while [ "$i" -lt "$total" ]; do
            name=$(jq -r ".[$i].name" "$ECLIPVPN_TMP/servers.json")
            host=$(jq -r ".[$i].host" "$ECLIPVPN_TMP/servers.json")
            if ! _is_auto_skipped "$name" "$muted"; then
                ms=$(_reach_ms "$host" "$(_server_protocol "$i")")
                if [ "$ms" -gt 0 ] 2>/dev/null; then
                    candidates="$candidates$ms $i\n"
                    [ "$i" = "$current_idx" ] && current_rtt="$ms"
                fi
            fi
            i=$((i + 1))
        done

        # Emergency pass — only when the current tunnel is actually BROKEN and
        # no un-muted server answered. Auto-eval otherwise runs as an
        # optimiser, and "everything else is a bit slow" must never be a reason
        # to move onto a billed exit; a dead tunnel is.
        if [ -z "$candidates" ] && [ "$current_broken" -eq 1 ] && [ -n "$muted" ]; then
            flog "Auto-mode: current broken and no un-muted candidate — retrying muted ones"
            i=0
            while [ "$i" -lt "$total" ]; do
                name=$(jq -r ".[$i].name" "$ECLIPVPN_TMP/servers.json")
                host=$(jq -r ".[$i].host" "$ECLIPVPN_TMP/servers.json")
                if ! _is_metered_server "$name" && _name_has_token "$name" "$muted"; then
                    ms=$(_reach_ms "$host" "$(_server_protocol "$i")")
                    if [ "$ms" -gt 0 ] 2>/dev/null; then
                        candidates="$candidates$ms $i\n"
                        [ "$i" = "$current_idx" ] && current_rtt="$ms"
                    fi
                fi
                i=$((i + 1))
            done
            [ -n "$candidates" ] && \
                _log_incident "emergency_muted" "" "" "текущий сервер не работает, свободных нет — переходим на замьюченный (тарифицируемый)"
        fi
        [ -z "$candidates" ] && exit 0

        local best_line best_rtt best_idx
        best_line=$(printf '%b' "$candidates" | sort -n | head -1)
        best_rtt=$(echo "$best_line" | awk '{print $1}')
        best_idx=$(echo "$best_line" | awk '{print $2}')

        [ "$best_idx" = "$current_idx" ] && exit 0   # already on best by RTT

        # Hysteresis. Three branches:
        #   - tunnel dead (test_xray empty)        → switch to anything working
        #   - current TCP unreachable but VPN ok   → switch to anything reachable
        #     (don't strand on a host we can't even reach by TCP)
        #   - both RTTs known                      → 30% OR 50ms improvement
        local should_switch=0
        if [ "$current_broken" -eq 1 ]; then
            should_switch=1
            flog "Auto-mode: current tunnel dead, looking for any working server"
        elif [ "$current_rtt" -le 0 ] && [ "$best_rtt" -gt 0 ]; then
            should_switch=1
            flog "Auto-mode: current TCP unreachable, switching to best reachable ($best_rtt ms)"
        elif [ "$current_rtt" -gt 0 ] && [ "$best_rtt" -gt 0 ]; then
            local rel=$((current_rtt * 7 / 10))     # 30% lower
            local abs=$((current_rtt - 50))         # 50ms lower
            if [ "$best_rtt" -lt "$rel" ] || [ "$best_rtt" -lt "$abs" ]; then
                should_switch=1
                flog "Auto-mode: $current_rtt ms → $best_rtt ms — switching"
            fi
        fi

        [ "$should_switch" -eq 0 ] && exit 0

        # Real VLESS probe before committing
        local probe
        probe=$(cmd_probe_server "$best_idx" 2>/dev/null)
        if ! echo "$probe" | jq -e '.status == "ok"' >/dev/null 2>&1; then
            flog "Auto-mode: best candidate failed VLESS probe — staying"
            exit 0
        fi

        # Commit + restart, with rollback on failure. Each cmd_restart runs in
        # its OWN subshell so the op-lock (released only on the restart's subshell
        # EXIT trap) doesn't make the rollback restart self-deadlock.
        update_config '.selected_server = $idx' --argjson idx "$best_idx"
        if ( cmd_restart ) >/dev/null 2>&1; then
            _record_switch "$current_idx" "$best_idx" "auto"
            jq --argjson t "$now" '.last_switch = $t' "$sf" > "${sf}.tmp" && mv "${sf}.tmp" "$sf"
            local bn
            bn=$(jq -r --argjson i "$best_idx" '.[$i].name' "$ECLIPVPN_TMP/servers.json")
            flog "Auto-mode: switched to $bn"
        else
            update_config '.selected_server = $idx' --argjson idx "$current_idx"
            ( cmd_restart ) >/dev/null 2>&1
            flog "Auto-mode: restart failed, rolled back"
        fi
    ) 9>"$oplock"
}

# --- mute list management ---------------------------------------------------
# `mute-server N` / `unmute-server N` toggle a server's NAME in the
# `muted_servers` token list (matcher: _name_has_token in usr/bin/eclipvpn).
#
# The list stores NAME SUBSTRINGS, never indices. The merged pool is rebuilt on
# every `update` and indices shift (that is the whole reason
# _remap_selected_server exists), so an index-keyed mute would drift onto the
# wrong server. A name token also mutes a whole family with one entry — a single
# "Обход" token covers every CDN relay the panel adds later.
#
# The index argument is used ONLY to resolve the name at click time.

# How many servers in the current pool a token list matches. Mirrors
# _apply_server_filter's jq: contains(), never test() — no Oniguruma here.
_muted_count() {
    local toks="$1"
    [ -n "$toks" ] || { echo 0; return 0; }
    [ -f "$ECLIPVPN_TMP/servers.json" ] || { echo 0; return 0; }
    jq --arg f "$toks" '
        ($f | split(",") | map(select(length>0))) as $t
        | [ .[] | . as $s | select($t | any(. as $k | ($s.name // "") | contains($k))) ]
        | length' "$ECLIPVPN_TMP/servers.json" 2>/dev/null || echo 0
}

# Resolve a pool index to a server name, with bounds + sanity checks.
# Echoes the name; non-zero on any problem.
#
# CAREFUL: _err writes its {"error":...} to STDOUT, and callers run this in a
# command substitution — so on failure the error JSON lands in the captured
# variable, not on the wire. Callers must re-emit it (see _mute_name_or_fail);
# swallowing it leaves the CGI returning an empty body and the UI showing a
# generic "не удалось" with the real reason lost.
_mute_resolve_name() {
    local idx="$1" cmd="$2"
    [ -f "$ECLIPVPN_TMP/servers.json" ] || { _err "$cmd: no servers (run update first)"; return 1; }
    case "$idx" in ''|*[!0-9]*) _err "$cmd: index must be a number"; return 1 ;; esac
    local total; total=$(jq 'length' "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    [ "$idx" -lt "$total" ] || { _err "$cmd: index $idx out of range (pool=$total)"; return 1; }
    local name; name=$(jq -r --argjson i "$idx" '.[$i].name // ""' "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
    [ -n "$name" ] || { _err "$cmd: server $idx has no name"; return 1; }
    # The list is comma-separated, so a name carrying a comma can never be a
    # token. Provider names don't normally have one; fail loudly instead of
    # silently storing a token that splits into two useless fragments.
    case "$name" in *,*) _err "$cmd: name contains a comma — edit set-config muted_servers by hand"; return 1 ;; esac
    printf '%s' "$name"
}

cmd_mute_server() {
    local name rc
    name=$(_mute_resolve_name "$1" "mute-server"); rc=$?
    [ "$rc" -eq 0 ] || { printf '%s\n' "$name"; return 1; }
    local muted; muted=$(_muted_tokens)
    if _name_has_token "$name" "$muted"; then
        jq -n --arg n "$name" --arg l "$muted" --argjson c "$(_muted_count "$muted")" \
            '{status:"unchanged", server:$n, muted:true, muted_servers:$l, muted_count:$c}'
        return 0
    fi
    local new="${muted:+$muted,}$name"
    [ "${#new}" -gt 400 ] && { _err "mute-server: muted_servers would exceed 400 chars"; return 1; }
    update_config '.muted_servers = $v' --arg v "$new" || { _err "mute-server: save failed"; return 1; }
    flog "Muted server (excluded from auto-select/failover): $name"
    jq -n --arg n "$name" --arg l "$new" --argjson c "$(_muted_count "$new")" \
        '{status:"muted", server:$n, muted:true, muted_servers:$l, muted_count:$c}'
}

cmd_unmute_server() {
    local name rc
    name=$(_mute_resolve_name "$1" "unmute-server"); rc=$?
    [ "$rc" -eq 0 ] || { printf '%s\n' "$name"; return 1; }
    local muted; muted=$(_muted_tokens)
    if ! _name_has_token "$name" "$muted"; then
        jq -n --arg n "$name" --arg l "$muted" --argjson c "$(_muted_count "$muted")" \
            '{status:"unchanged", server:$n, muted:false, muted_servers:$l, muted_count:$c}'
        return 0
    fi
    # Drop EVERY token this name matches, not just an exact-name one: the server
    # may be muted through a FAMILY token ("Обход"), and removing only an exact
    # match would leave the button visibly doing nothing. `removed` rides out so
    # the UI can warn that un-muting one CDN relay un-muted its siblings too.
    local new="" removed="" tok rest
    rest="$muted"
    while [ -n "$rest" ]; do
        case "$rest" in
            *,*) tok="${rest%%,*}"; rest="${rest#*,}" ;;
            *)   tok="$rest"; rest="" ;;
        esac
        [ -n "$tok" ] || continue
        case "$name" in
            *"$tok"*) removed="${removed:+$removed,}$tok"; continue ;;
        esac
        new="${new:+$new,}$tok"
    done
    update_config '.muted_servers = $v' --arg v "$new" || { _err "unmute-server: save failed"; return 1; }
    flog "Unmuted server: $name (dropped tokens: $removed)"
    jq -n --arg n "$name" --arg l "$new" --arg r "$removed" --argjson c "$(_muted_count "$new")" \
        '{status:"unmuted", server:$n, muted:false, muted_servers:$l, muted_count:$c,
          removed_tokens:($r | split(",") | map(select(length>0)))}'
}
