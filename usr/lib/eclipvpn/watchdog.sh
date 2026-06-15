#!/bin/ash
# EclipVPN — watchdog: connectivity probing, auto-failover, throughput guard.
# Sourced into /usr/bin/eclipvpn; shares its globals ($ECLIPVPN_TMP, etc.) and
# helpers (flog, get_config_val, save_config, is_xray_running/is_singbox_running,
# cmd_restart, generate_xray_config, _log_incident, _record_switch,
# _is_metered_server, _rotate_log, _apply_wan_mtu, cmd_auto_eval). All are
# resolved at call time, so source order among the libs does not matter.

# Multi-endpoint probe via SOCKS:$1. Returns 0 on success (≥1 endpoint OK),
# 1 on fail (all down). Sets WD_PROBE_WHY for incident logging on failure.
# Endpoint order: cheapest/most-reliable first. cp.cloudflare.com & gstatic
# are captive-portal probes — both return HTTP 204 with empty body, ~200B
# wire size. ipify is heavier (returns IP as text) but useful as third
# opinion if both CF and Google are simultaneously routing-flaky.
_watchdog_probe_via_socks() {
    local socks_port="${1:-1080}"
    WD_PROBE_WHY=""
    local first_rc="" first_code="" first_time=""
    for url in https://cp.cloudflare.com/generate_204 \
               http://www.gstatic.com/generate_204 \
               https://api.ipify.org; do
        local out rc code total_time
        out=$(curl -s --socks5-hostname "127.0.0.1:$socks_port" --max-time 6 \
              -o /dev/null -w "%{http_code} %{time_total}" "$url" 2>/dev/null)
        rc=$?
        code="${out%% *}"; total_time="${out##* }"
        if [ "$code" = "204" ] || [ "$code" = "200" ]; then
            return 0
        fi
        # Save reason from FIRST endpoint that failed — most informative
        # because subsequent ones may legitimately differ (e.g. CF blocked
        # but gstatic ok = not really "VPN broken").
        [ -z "$first_rc" ] && { first_rc=$rc; first_code=$code; first_time=$total_time; }
    done
    case "$first_rc" in
        0)  WD_PROBE_WHY="HTTP $first_code за ${first_time}с" ;;
        6)  WD_PROBE_WHY="DNS не разрешился" ;;
        7)  WD_PROBE_WHY="прокси не отвечает (xray:$socks_port)" ;;
        28) WD_PROBE_WHY="таймаут >6с (HTTP $first_code)" ;;
        35) WD_PROBE_WHY="ошибка TLS handshake" ;;
        52) WD_PROBE_WHY="пустой ответ от сервера" ;;
        56) WD_PROBE_WHY="разрыв соединения" ;;
        *)  WD_PROBE_WHY="curl rc=$first_rc, HTTP $first_code" ;;
    esac
    return 1
}

# Direct (non-SOCKS) WAN reachability test. Detects "ISP outage" so we don't
# blame the VPN server for problems upstream of us. 1.1.1.1 and 9.9.9.9 are
# anycast and effectively never down simultaneously — if both refuse a
# 3-second TCP connect, the WAN itself is the problem, not the tunnel.
# Note: curl exit 0 means the TLS handshake completed (and got a response,
# even a redirect). exit 7/28 = no route / timeout. We only need a connect.
_watchdog_check_wan() {
    curl -sS --max-time 3 --connect-timeout 3 -o /dev/null https://1.1.1.1 2>/dev/null && return 0
    curl -sS --max-time 3 --connect-timeout 3 -o /dev/null https://9.9.9.9 2>/dev/null && return 0
    return 1
}

# Measure tunnel throughput through SOCKS:$1, in KB/s (integer, stdout).
# Pulls a small ranged payload from CDNs that DON'T throttle datacenter /
# VPN exit IPs — speedtest endpoints (speed.cloudflare.com, speed.hetzner.de)
# deliberately rate-limit such IPs and would lie about a healthy server.
# Takes the BEST of two independent CDNs so one blocked/flaky mirror can't
# fake a "slow server". Prints nothing if BOTH fail — the caller treats an
# empty reading as "no data" (NOT "slow"), so our own probe glitch never
# triggers a false failover.
_watchdog_throughput_kbps() {
    local port="$1" best=0
    local url sp kbps
    for url in https://cachefly.cachefly.net/10mb.test \
               https://proof.ovh.net/files/10Mb.dat; do
        sp=$(curl -s --socks5-hostname "127.0.0.1:$port" -r 0-4000000 \
             --connect-timeout 4 --max-time 6 -o /dev/null \
             -w "%{speed_download}" "$url" 2>/dev/null)
        [ -z "$sp" ] && continue
        kbps=$(awk -v s="$sp" 'BEGIN{printf "%d", s/1024}')
        [ "$kbps" -gt "$best" ] && best=$kbps
    done
    [ "$best" -gt 0 ] && echo "$best"
}

# Spawn a throwaway proxy engine (xray, or a sing-box dialer for hysteria2) for
# server index $1 on SOCKS port $2 and measure it.
# $3 metric: latency (default) → ms; throughput → KB/s (0 = answered the
# reachability probe but moved no data). Echoes "ok <value>" on success or
# "fail <http-code>" if the server never answered — callers run this via
# $(...), a subshell, so a result can only come back on stdout (a global
# var set in here never reaches them; that bug shipped once). Used by
# _watchdog_pick_best for failover candidates and by the throughput guard's
# re-dial check against the CURRENT server.
# Two spawn-and-probe attempts, fresh xray for the second. The first request
# through a cold VLESS+XHTTP+Reality session hangs to full timeout ~50% of
# the time on some endpoints — the same flake cmd_probe_server retries 4×
# for. A single-shot probe falsely rejected healthy failover candidates,
# which surfaced as "no working candidates" during recoverable outages.
# Waiting for the SOCKS port to listen (instead of a blind sleep 2) makes
# the common case faster, not slower.
_watchdog_probe_candidate() {
    local idx="$1" pp="$2" metric="${3:-latency}"
    # Single throwaway config; engine-aware (hysteria2 → sing-box dialer, else
    # xray). .json suffix needed for xray's format sniff; mktemp+rename.
    local _wp wd_probe eng
    _wp=$(mktemp "$ECLIPVPN_TMP/wd_probe.XXXXXX")
    wd_probe="${_wp}.json"; mv "$_wp" "$wd_probe"
    eng=$(_gen_probe_config "$idx" "$pp" "$wd_probe") || { rm -f "$wd_probe" "${wd_probe}.base"; echo "fail none"; return; }
    local out="" code="" t="" probe_pid="" attempt
    for attempt in 1 2; do
        if [ "$eng" = "singbox" ]; then
            /usr/bin/sing-box run -c "$wd_probe" -D "$ECLIPVPN_TMP" >/dev/null 2>&1 &
        else
            /usr/bin/xray run -config "$wd_probe" >/dev/null 2>&1 &
        fi
        probe_pid=$!
        local ready=0 wait_i=0
        while [ "$wait_i" -lt 5 ]; do
            kill -0 "$probe_pid" 2>/dev/null || break
            if netstat -tlnp 2>/dev/null | grep -q ":$pp "; then
                ready=1; break
            fi
            sleep 1; wait_i=$((wait_i + 1))
        done
        if [ "$ready" -eq 1 ]; then
            out=$(curl -s --socks5-hostname "127.0.0.1:$pp" --max-time 5 \
                  -o /dev/null -w "%{http_code} %{time_total}" \
                  https://cp.cloudflare.com/generate_204 2>/dev/null)
            code="${out%% *}"; t="${out##* }"
            if [ "$code" = "204" ] || [ "$code" = "200" ]; then break; fi
        fi
        # Failed attempt: respawn rather than retry the same xray — a
        # hung cold session never recovers within its own process.
        kill "$probe_pid" 2>/dev/null; wait "$probe_pid" 2>/dev/null
        probe_pid=""
    done
    local value=""
    if [ "$code" = "204" ] || [ "$code" = "200" ]; then
        if [ "$metric" = "throughput" ]; then
            # Measure while the probe-xray is still alive.
            value=$(_watchdog_throughput_kbps "$pp")
            value="${value:-0}"
        else
            value=$(awk -v t="$t" 'BEGIN { printf "%d", t*1000 }')
        fi
    fi
    [ -n "$probe_pid" ] && { kill "$probe_pid" 2>/dev/null; wait "$probe_pid" 2>/dev/null; }
    rm -f "$wd_probe" "${wd_probe}.base"
    if [ -n "$value" ]; then echo "ok $value"; else echo "fail ${code:-none}"; fi
}

# Pick best non-metered, non-current candidate. metric=latency (default)
# selects lowest probe latency; metric=throughput measures actual tunnel
# speed per candidate and selects highest KB/s — used by the throughput
# guard, since a peak-shaped server pings fast but moves no data, so latency
# would happily pick another equally-throttled node. Echoes "<idx> <value>"
# (value = ms for latency, KB/s for throughput) or empty if none answered.
# Spawns a probe-xray per candidate sequentially; throughput mode adds one
# small download per candidate (only runs on a real degradation event).
_watchdog_pick_best() {
    local current="$1" total="$2" probe_port="$3" metric="${4:-latency}"
    local servers_json="$ECLIPVPN_TMP/servers.json"
    local best_idx="" best_ms=99999 best_kbps=-1
    local i=0
    while [ "$i" -lt "$total" ]; do
        if [ "$i" -eq "$current" ]; then i=$((i+1)); continue; fi
        local cand_name=$(jq -r ".[$i].name" "$servers_json" 2>/dev/null)
        if _is_metered_server "$cand_name"; then
            i=$((i+1)); continue
        fi
        local res=$(_watchdog_probe_candidate "$i" "$probe_port" "$metric")
        if [ "${res%% *}" = "ok" ]; then
            local val="${res#ok }"
            if [ "$metric" = "throughput" ]; then
                logger -t eclipvpn "Watchdog: $cand_name ${val}KB/s"
                if [ "$val" -gt "$best_kbps" ]; then
                    best_kbps=$val; best_idx=$i
                fi
            else
                logger -t eclipvpn "Watchdog: $cand_name probe ${val}ms"
                if [ "$val" -lt "$best_ms" ]; then
                    best_ms=$val; best_idx=$i
                fi
            fi
        else
            logger -t eclipvpn "Watchdog: $cand_name probe failed (code=${res#fail })"
        fi
        i=$((i+1))
    done
    if [ -n "$best_idx" ]; then
        if [ "$metric" = "throughput" ]; then echo "$best_idx $best_kbps"; else echo "$best_idx $best_ms"; fi
    fi
}

cmd_watchdog() {
    local interval="${1:-20}" max_fails=5 fail_count=0 tick=0 silent_fails=0
    # Throughput-guard state (see the guard block on the connectivity-OK path).
    # tput_switch_helped: 1 = at least one good reading since the last
    # throughput switch/benchmark — the cooldown only gates while it's 0.
    # tput_redialed: 1 = this incident already spent its one in-place re-dial.
    # tput_fast_retry_used: 1 = the one early retry after a flopped action
    # (no good reading since) has been spent — next gate is the full cooldown.
    local slow_count=0 last_tput_switch=0 tput_switch_helped=1
    local tput_redialed=0 tput_fast_retry_used=0
    local TPUT_EVERY=6        # measure current-server speed every ~2 min (6×20s)
    local TPUT_SLOW_MAX=3     # consecutive low reads before acting (~6 min sustained)
    local TPUT_COOLDOWN=1200  # min seconds between throughput-driven switches (anti-flap)
    local TPUT_COOLDOWN_FAST=300  # the single early retry after a flop comes this soon

    # Single-instance via atomic mkdir. The earlier file-based lock was
    # unreliable: under the init.d/cmd_start spawn race the lock would end
    # up empty/missing while a watchdog was alive, so every subsequent
    # _ensure_watchdog spawned a duplicate. Killing peers from cmd_watchdog
    # also raced with traps not yet installed, sometimes wiping all of them.
    # mkdir is the only POSIX-portable atomic-create primitive available
    # on busybox without flock — it gives "first wins, others exit cleanly".
    local me=$$
    local lockdir="$ECLIPVPN_TMP/watchdog.lockdir"
    mkdir -p "$ECLIPVPN_TMP"
    while ! mkdir "$lockdir" 2>/dev/null; do
        local owner
        owner=$(cat "$lockdir/owner" 2>/dev/null)
        if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
            rm -rf "$lockdir"  # stale — owner died without cleanup, retry
            continue
        fi
        return 0  # peer alive, we're a duplicate
    done
    echo "$me" > "$lockdir/owner"
    trap 'rm -rf "$lockdir"; flog "Watchdog stopped"; exit 0' TERM INT EXIT
    # Mirror the owner PID into the legacy lock path for stop()/status code
    # that still reads watchdog.lock.
    echo "$me" > "$ECLIPVPN_TMP/watchdog.lock"

    # Unique probe port per-process — survives concurrent set-server probes
    # and other ad-hoc xray runs that might collide on a fixed port.
    # Base 1182, NOT cmd_probe_server's 1082: the ranges must not overlap,
    # or a CLI/UI probe in another process could land on the same port as a
    # concurrent failover scan and curl through the wrong server's xray.
    local probe_port=$((1182 + $$ % 100))

    while true; do
        sleep "$interval"
        tick=$((tick + 1))

        # Rotate logs every ~3 minutes (10 ticks × 20s). Sing-box at warn
        # level is quiet, but we still want quick recovery if log noise
        # ever spikes (e.g. xray reconnect storm).
        [ $((tick % 10)) -eq 0 ] && _rotate_log

        # fd pressure check every ~10 min (30 ticks). fd exhaustion kills xray
        # with no useful log line (XKeen's most-reported crash cause) — a
        # warning here lets syslog explain a later crash/restart loop.
        if [ $((tick % 30)) -eq 0 ]; then
            local _fdname _fdp _fdn _fdl
            for _fdname in xray singbox; do
                _fdp=$(cat "$ECLIPVPN_TMP/${_fdname}.pid" 2>/dev/null)
                [ -n "$_fdp" ] && [ -d "/proc/$_fdp/fd" ] || continue
                _fdn=$(ls "/proc/$_fdp/fd" 2>/dev/null | wc -l)
                _fdl=$(awk '/^Max open files/{print $4}' "/proc/$_fdp/limits" 2>/dev/null)
                case "$_fdl" in ''|*[!0-9]*) continue ;; esac
                [ $((_fdn * 10)) -ge $((_fdl * 9)) ] && \
                    logger -t eclipvpn "Watchdog: $_fdname fd usage high: $_fdn/$_fdl"
            done
        fi

        # Auto-mode periodic re-evaluation every ~20 minutes (60 ticks).
        # cmd_auto_eval has its own internal rate-limit and hysteresis,
        # so it's safe to call this frequently — actual switches happen
        # at most once per hour and only on meaningful improvement.
        if [ $((tick % 60)) -eq 0 ]; then
            local _am
            _am=$(get_config_val auto_mode false)
            [ "$_am" = "true" ] && cmd_auto_eval >/dev/null 2>&1
        fi

        # Auto-recovery: if user wanted VPN on (running_intent=true) but
        # processes died externally — kernel OOM-killer, manual pkill, an
        # xray crash — bring them back. With cooldown to prevent runaway
        # restart loops if cmd_start itself keeps failing (e.g. provider
        # blocked, server keys rotated): if we already tried recently and
        # still no xray, wait — don't pile up zombie children.
        if ! _vpn_running; then
            # Defer revival if a user-initiated lifecycle command is in
            # flight. cmd_restart's brief stop_xray window otherwise tricks
            # us into revival, which then races the rest of cmd_restart and
            # spawns a parallel xray.
            local op_marker="$ECLIPVPN_TMP/op.in_progress"
            if [ -f "$op_marker" ]; then
                local op_pid=$(cat "$op_marker" 2>/dev/null)
                if [ -n "$op_pid" ] && kill -0 "$op_pid" 2>/dev/null; then
                    continue
                fi
                # Stale marker — owning process is dead, fall through and
                # remove on the way out so we don't get stuck deferring forever.
                rm -f "$op_marker"
            fi

            local _intent
            _intent=$(get_config_val running_intent false)
            if [ "$_intent" = "true" ]; then
                local revive_marker="$ECLIPVPN_TMP/last_revive"
                local now=$(date +%s)
                local last=0
                [ -f "$revive_marker" ] && last=$(cat "$revive_marker" 2>/dev/null)
                [ -z "$last" ] && last=0
                # Min 60s between revival attempts. cmd_start needs ~7s to
                # complete; this gives it room to finish + brief settle time.
                if [ $((now - last)) -lt 60 ]; then
                    : # in cooldown — skip this tick silently
                else
                    flog "Watchdog: VPN was killed externally, reviving"
                    echo $now > "$revive_marker"
                    # Subshell: cmd_start's `trap _op_end EXIT` only fires on
                    # process exit, and the watchdog never exits. A bare call
                    # would leak op.lockdir forever (owner=watchdog), wedging
                    # every later user lifecycle op. The subshell makes EXIT
                    # fire on its own exit, releasing the lock.
                    ( cmd_start ) >/dev/null 2>&1
                fi
            fi
            continue
        fi

        # Skip if not running (intent=false — user wanted VPN off)
        _vpn_running || continue

        # Re-assert the WAN MTU cap (idempotent, ~one sysfs read when already
        # applied). A soft cmd_restart preserves it, but a DHCP renew / netifd
        # reconfigure can silently reset the interface to 1500 mid-session and
        # the PMTU-blackhole slowdown would creep back; this self-heals it.
        _apply_wan_mtu

        # Multi-endpoint VPN connectivity probe: try CF, gstatic, ipify in
        # order. Success on the first that responds 200/204. Reduces false
        # positives where one captive-portal endpoint glitches but the
        # tunnel is fine (real-world: cp.cloudflare.com periodically returns
        # 5xx during CF maintenance windows — a single-endpoint probe would
        # have failed-over the user to a worse server for no reason).
        if _watchdog_probe_via_socks 1080; then
            # If we were tracking a WAN outage, close it out with a single
            # "recovered" incident and clear the streak markers. Without
            # this, an outage that started at 08:24 and ended at 08:28
            # would just leave the journal stuck on its last wan_down line
            # with no indication things came back.
            local wan_marker="$ECLIPVPN_TMP/wan_down_since"
            if [ -f "$wan_marker" ]; then
                local since=$(cat "$wan_marker" 2>/dev/null)
                local ticks=$(cat "$ECLIPVPN_TMP/wan_down_ticks" 2>/dev/null || echo 0)
                local duration_s=$(( $(date +%s) - ${since:-$(date +%s)} ))
                logger -t eclipvpn "Watchdog: WAN recovered after ${duration_s}s ($ticks ticks)"
                _log_incident "wan_recovered" "" "" "восстановлен через ${duration_s}с (было ${ticks} проверок без связи)"
                rm -f "$wan_marker" "$ECLIPVPN_TMP/wan_down_ticks"
            fi
            [ "$silent_fails" -gt 0 ] && logger -t eclipvpn "Watchdog: connectivity restored (was failing $silent_fails ticks)"
            fail_count=0
            silent_fails=0

            # --- Throughput guard ------------------------------------------
            # The probe above only proves the server ANSWERS. A peak-overloaded
            # exit pings fast and returns 204 instantly while its bandwidth is
            # shaped to a crawl — latency-based failover never fires, but the
            # user sees "everything is molasses". Periodically measure REAL
            # tunnel throughput; if it collapses for several consecutive
            # checks, act in two stages:
            #   1. RE-DIAL: the policer pins flows per-TCP-connection (root
            #      cause 2026-06-11) — a fresh flow to the SAME exit often
            #      escapes the squeeze while the live tunnel's pinned flow
            #      crawls (probe 11.7MB/s vs live 199KB/s on one server,
            #      2026-06-12). If a throwaway xray to the current server
            #      measures clearly fast, force-restart in place (new flows,
            #      same server) instead of burning a switch. One attempt per
            #      incident.
            #   2. SWITCH: fail over to the candidate with the best MEASURED
            #      speed (not latency).
            # Anti-flap is layered: a switch needs a candidate clearly faster
            # (>2×) than the crawl, and the cooldown applies only while the
            # last switch/benchmark produced no good reading since
            # (tput_switch_helped=0 — the "every server is throttled" peak).
            # A switch that DID restore speed and later got re-squeezed
            # (rolling TSPU waves, observed 2026-06-10) may act again as soon
            # as TPUT_SLOW_MAX low reads re-accumulate (~7 min), not 20.
            # And after a FLOPPED action (squeezed before any good reading —
            # the per-flow lottery lost) the FIRST re-action is allowed after
            # TPUT_COOLDOWN_FAST, not the full cooldown: on 2026-06-12 a
            # switch flopped while a free server existed, and the full gate
            # left the user at 250KB/s for 10 min until a manual switch. One
            # early retry catches that; a second consecutive flop means the
            # peak really is everywhere — wait out the full 20 min.
            if [ "$(get_config_val tput_guard true)" = "true" ] && [ $((tick % TPUT_EVERY)) -eq 0 ]; then
                local min_kbps; min_kbps=$(get_config_val tput_min_kbps 500)
                case "$min_kbps" in ''|*[!0-9]*) min_kbps=500 ;; esac
                local kbps; kbps=$(_watchdog_throughput_kbps 1080)
                if [ -n "$kbps" ] && [ "$kbps" -lt "$min_kbps" ]; then
                    slow_count=$((slow_count + 1))
                    logger -t eclipvpn "Watchdog: low throughput ${kbps}KB/s < ${min_kbps} ($slow_count/$TPUT_SLOW_MAX)"
                else
                    [ "$slow_count" -gt 0 ] && [ -n "$kbps" ] && logger -t eclipvpn "Watchdog: throughput recovered (${kbps}KB/s)"
                    # A real good reading (not an empty no-data probe) proves
                    # the current server delivers — the next degradation is a
                    # fresh wave, not the same incident: lift the cooldown gate
                    # and re-arm the per-incident re-dial / early-retry budgets.
                    [ -n "$kbps" ] && { tput_switch_helped=1; tput_redialed=0; tput_fast_retry_used=0; }
                    slow_count=0
                fi

                if [ "$slow_count" -ge "$TPUT_SLOW_MAX" ]; then
                    local now=$(date +%s)
                    local cool=$TPUT_COOLDOWN
                    [ "$tput_fast_retry_used" -eq 0 ] && cool=$TPUT_COOLDOWN_FAST
                    if [ $((now - last_tput_switch)) -lt "$cool" ] && [ "$tput_switch_helped" -eq 0 ]; then
                        : # last switch/benchmark never lifted things — cool down, don't flap
                    else
                        # Acting from a helped=0 state means this IS the one
                        # early retry — spend it.
                        [ "$tput_switch_helped" -eq 0 ] && tput_fast_retry_used=1
                        local cur_idx=$(get_config_val selected_server 0)
                        local total=$(jq 'length' "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                        local cur_name=$(jq -r ".[$cur_idx].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                        local cur_host=$(jq -r ".[$cur_idx].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                        local did_redial=0
                        if [ "$tput_redialed" -eq 0 ]; then
                            tput_redialed=1
                            logger -t eclipvpn "Watchdog: throughput degraded on $cur_name (${kbps}KB/s) — probing a fresh flow to it"
                            local fres=$(_watchdog_probe_candidate "$cur_idx" "$probe_port" throughput)
                            local fresh_kbps=""
                            [ "${fres%% *}" = "ok" ] && fresh_kbps="${fres#ok }"
                            if [ -n "$fresh_kbps" ] && [ "$fresh_kbps" -ge "$min_kbps" ] && [ "$fresh_kbps" -gt $((kbps * 2)) ]; then
                                logger -t eclipvpn "Watchdog: re-dialing $cur_name in place (fresh flow ${fresh_kbps}KB/s vs ${kbps}KB/s)"
                                _log_incident "slow_redial" "$cur_host" "$cur_name" "низкая скорость (${kbps}КБ/с), свежий поток к тому же серверу даёт ${fresh_kbps}КБ/с — переподключение без смены сервера"
                                # Force (=1) past the unchanged-config fast
                                # path: configs are byte-identical and the
                                # tunnel answers probes, so a plain restart
                                # would no-op instead of replacing the flows.
                                ( cmd_restart 1 ) >/dev/null 2>&1
                                last_tput_switch=$(date +%s)
                                tput_switch_helped=0
                                slow_count=0
                                did_redial=1
                                sleep $((interval * 3))
                            else
                                logger -t eclipvpn "Watchdog: fresh flow to $cur_name also slow (${fresh_kbps:-0}KB/s)"
                            fi
                        fi
                        if [ "$did_redial" -eq 0 ]; then
                        logger -t eclipvpn "Watchdog: throughput degraded on $cur_name (${kbps}KB/s) — benchmarking servers"
                        if [ -n "$total" ] && [ "$total" -gt 1 ]; then
                            local pick=$(_watchdog_pick_best "$cur_idx" "$total" "$probe_port" throughput)
                            if [ -n "$pick" ]; then
                                local sel="${pick%% *}" cand_kbps="${pick##* }"
                                # Switch ONLY if the best alternative clears the threshold AND
                                # is clearly faster (>2×) than the current crawl. If every node
                                # is throttled at peak, a switch is just a pointless blip.
                                if [ "$cand_kbps" -ge "$min_kbps" ] && [ "$cand_kbps" -gt $((kbps * 2)) ]; then
                                    local sel_name=$(jq -r ".[$sel].name" "$ECLIPVPN_TMP/servers.json")
                                    local sel_host=$(jq -r ".[$sel].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                                    logger -t eclipvpn "Watchdog: switching to $sel_name (${cand_kbps}KB/s vs ${kbps}KB/s)"
                                    _log_incident "slow_degraded" "$sel_host" "$sel_name" "низкая скорость на $cur_name (${kbps}КБ/с) → $sel_name (${cand_kbps}КБ/с)"
                                    _record_switch "$cur_idx" "$sel" "throughput"
                                    local tmp=$(jq --argjson idx "$sel" '.selected_server = $idx' "$ECLIPVPN_CONFIG")
                                    save_config "$tmp" || flog "WARN: throughput failover save_config failed"
                                    ( cmd_restart ) >/dev/null 2>&1
                                    last_tput_switch=$(date +%s)
                                    tput_switch_helped=0
                                    tput_redialed=0  # new server gets its own re-dial chance
                                    slow_count=0
                                    sleep $((interval * 3))
                                else
                                    logger -t eclipvpn "Watchdog: all servers slow (best ${cand_kbps}KB/s) — staying put"
                                    _log_incident "slow_noalt" "$cur_host" "$cur_name" "скорость низкая везде (текущий ${kbps}КБ/с, лучший кандидат ${cand_kbps}КБ/с)"
                                    last_tput_switch=$(date +%s)
                                    tput_switch_helped=0
                                    slow_count=0
                                fi
                            else
                                logger -t eclipvpn "Watchdog: no throughput candidates answered — staying put"
                                last_tput_switch=$(date +%s)
                                tput_switch_helped=0
                                slow_count=0
                            fi
                        fi
                        fi
                    fi
                fi
            fi
            # --- end throughput guard --------------------------------------
            continue
        fi
        local why="$WD_PROBE_WHY"

        # WAN sanity check: if our own internet is down, the VPN server is
        # not at fault — switching would just pick a random working-looking
        # candidate (or none) and pollute incidents with false-positives.
        # Record the WAN outage as its own incident type and skip the
        # fail_count bump so the user doesn't see a phantom server-degraded
        # warning during ISP downtime.
        #
        # Dedup: we log only on the FIRST tick of a WAN outage (no marker
        # yet) and silently count subsequent ticks. Prevents the journal
        # from filling with 12 identical wan_down entries during a 4-min
        # ISP glitch — the recovery path above will emit a single
        # wan_recovered line summarising the streak.
        if ! _watchdog_check_wan; then
            local wan_marker="$ECLIPVPN_TMP/wan_down_since"
            if [ ! -f "$wan_marker" ]; then
                date +%s > "$wan_marker"
                echo 1 > "$ECLIPVPN_TMP/wan_down_ticks"
                logger -t eclipvpn "Watchdog: WAN down — provider issue, not switching ($why)"
                local _cur_idx=$(get_config_val selected_server 0)
                local _cur_name=$(jq -r ".[$_cur_idx].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                local _cur_host=$(jq -r ".[$_cur_idx].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                _log_incident "wan_down" "$_cur_host" "$_cur_name" "WAN недоступен ($why)"
            else
                local n=$(cat "$ECLIPVPN_TMP/wan_down_ticks" 2>/dev/null || echo 0)
                echo $((n + 1)) > "$ECLIPVPN_TMP/wan_down_ticks"
            fi
            continue
        fi

        fail_count=$((fail_count + 1))
        # Throttle "check failed" logs after the failover loop already ran —
        # otherwise a permanent outage spams syslog every 20s forever.
        # Persist incident only at >=3/5 — single isolated failures (1/5,
        # 2/5) are typically transient TLS jitter that resolves on the
        # next tick and used to clutter the journal with false positives.
        # The 5/5 final fail still drives the switch path unchanged.
        if [ "$fail_count" -le "$max_fails" ]; then
            logger -t eclipvpn "Watchdog: server check failed ($fail_count/$max_fails): $why"
            if [ "$fail_count" -ge 3 ]; then
                local _cur_idx=$(get_config_val selected_server 0)
                local _cur_name=$(jq -r ".[$_cur_idx].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                local _cur_host=$(jq -r ".[$_cur_idx].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                _log_incident "check_fail" "$_cur_host" "$_cur_name" "$why ($fail_count/$max_fails)"
            fi
        else
            silent_fails=$((silent_fails + 1))
            # One reminder every ~5 min while still down
            [ $((silent_fails % 15)) -eq 0 ] && logger -t eclipvpn "Watchdog: still no connectivity ($silent_fails ticks since last switch): $why"
        fi

        # Fire the failover scan at max_fails, then re-fire every 15 ticks
        # (~5 min) while the outage persists. The original `-eq max_fails`
        # fired exactly once: after a scan that found no candidates,
        # fail_count kept climbing past max_fails and the switch path was
        # disarmed until a probe happened to succeed — a dead current server
        # stayed selected even when alternatives came back hours later.
        if [ "$fail_count" -ge "$max_fails" ] && [ $(( (fail_count - max_fails) % 15 )) -eq 0 ]; then
            logger -t eclipvpn "Watchdog: switching server (cause: $why)"

            local current=$(get_config_val selected_server 0)
            local total=$(jq 'length' "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
            [ -z "$total" ] && continue

            # Probe ALL non-metered, non-current candidates and pick the one
            # with lowest latency — not the first one that happens to answer.
            # Old round-robin from current+1 caused USA to win whenever
            # Germany failed (next index) even though Finland & Netherlands
            # were both noticeably faster.
            local pick=$(_watchdog_pick_best "$current" "$total" "$probe_port")
            if [ -n "$pick" ]; then
                local selected="${pick% *}" best_ms="${pick##* }"
                local cand_name=$(jq -r ".[$selected].name" "$ECLIPVPN_TMP/servers.json")
                local _cand_host=$(jq -r ".[$selected].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                local _from_name=$(jq -r ".[$current].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                logger -t eclipvpn "Watchdog: switched to $cand_name (best of pool, ${best_ms}ms)"
                _log_incident "auto_switch" "$_cand_host" "$cand_name" "после $max_fails сбоев на $_from_name → лучший по latency: ${best_ms}мс ($why)"
                _record_switch "$current" "$selected" "failover"
                local tmp=$(jq --argjson idx "$selected" '.selected_server = $idx' "$ECLIPVPN_CONFIG")
                save_config "$tmp" || flog "WARN: failover save_config failed (will retry next tick)"
                # Subshell so cmd_restart's EXIT trap releases the op-lock —
                # see the revival call above; a bare call leaks it forever.
                ( cmd_restart ) >/dev/null 2>&1
                fail_count=0
                silent_fails=0
                # Give the new server time to stabilize before next probe.
                # Without this, a flaky network triggers cascading failovers.
                sleep $((interval * 3))
            else
                # No candidate answered — could be everything blocked, key
                # rotation, or a flaky upstream. Stay put, back off.
                logger -t eclipvpn "Watchdog: no working candidates — staying on current server ($why)"
                local _cur_name=$(jq -r ".[$current].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                local _cur_host=$(jq -r ".[$current].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
                _log_incident "switch_failed" "$_cur_host" "$_cur_name" "все кандидаты недоступны"
            fi
        fi
    done
}
