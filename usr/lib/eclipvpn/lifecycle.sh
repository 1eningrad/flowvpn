#!/bin/ash
# EclipVPN — lifecycle: start / stop / restart / status.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers, all
# resolved at call time, so source order among the libs does not matter.

# Bring up the proxy engine(s) for server index $1 in mode $2, assuming any
# previous daemons are already stopped. Engine-aware (see usr/bin/eclipvpn):
#   - xray protocols (vless/vmess/trojan/shadowsocks): start xray (SOCKS:1080),
#     verify the tunnel, then sing-box (tproxy/routing, "default" = socks→xray).
#   - hysteria2: start ONLY sing-box — it dials the exit natively and serves its
#     own SOCKS:1080; xray is never launched.
# Echoes the VPN exit IP on success (rc 0). On failure leaves daemons stopped
# and returns: 1 engine config/start failed, 2 tunnel test returned no IP,
# 3 sing-box failed to start. The shared test_xray (curls 127.0.0.1:1080)
# verifies the live tunnel for BOTH engines.
_tunnel_bringup() {
    local sel="$1" mode="$2" engine ip
    engine=$(_engine_for_protocol "$(_server_protocol "$sel")")

    if [ "$engine" = "singbox" ]; then
        # hysteria2 is QUIC — pre-flight the binary's build tags. A sing-box
        # without with_quic silently lacks the hysteria2 outbound and would
        # fail config load; surface a clear reason instead of a cryptic crash.
        if ! /usr/bin/sing-box version 2>/dev/null | grep -q 'with_quic'; then
            flog "ERROR: installed sing-box lacks QUIC (with_quic) — Hysteria2 not supported on this build"
            return 1
        fi
        flog "Starting sing-box (Hysteria2 native, server index=$sel, mode=$mode)"
        rm -f "$ECLIPVPN_TMP/xray_port"   # hysteria2 engine has no active xray
        generate_singbox_config "$ECLIPVPN_TMP/singbox.json" "$mode" "$ECLIPVPN_TMP/servers.json" "$sel" \
            || { flog "ERROR: sing-box config generation failed"; return 3; }
        start_singbox "$ECLIPVPN_TMP/singbox.json" || return 3
        ip=$(test_xray 1080)   # curls SOCKS:1080 — served by sing-box in this mode
        [ -z "$ip" ] && { stop_singbox; return 2; }
        flog "Hysteria2 tunnel up, VPN IP: $ip"
        printf '%s' "$ip"
        return 0
    fi

    # xray engine (vless / vmess / trojan / shadowsocks). Cold start brings the
    # active xray up on the canonical port 1080 (config xray.1080.json); the
    # active port only rotates on a seamless switch (see cmd_restart).
    flog "Starting xray (server index=$sel, port 1080)"
    generate_xray_config "$ECLIPVPN_TMP/servers.json" "$sel" "$ECLIPVPN_TMP/xray.1080.json" 1080 \
        || { flog "ERROR: xray config generation failed"; return 1; }
    start_xray "$ECLIPVPN_TMP/xray.1080.json" 1080 || return 1
    echo 1080 > "$ECLIPVPN_TMP/xray_port"
    ip=$(test_xray 1080)
    # Cosmetic cleanup on failure (found in review 2026-09-16): xray_port
    # already written above is harmless either way (absent ⇒ 1080, same
    # value), since _vpn_running/_vpn_live gate on actual process liveness,
    # not this file — but leave no stale state behind on a failed bring-up.
    [ -z "$ip" ] && { stop_xray 1080; rm -f "$ECLIPVPN_TMP/xray_port"; return 2; }
    flog "xray connected, VPN IP: $ip"
    generate_singbox_config "$ECLIPVPN_TMP/singbox.json" "$mode" "$ECLIPVPN_TMP/servers.json" "$sel" 1080 \
        || { flog "ERROR: sing-box config generation failed"; stop_xray 1080; return 3; }
    start_singbox "$ECLIPVPN_TMP/singbox.json" || { stop_xray 1080; return 3; }
    printf '%s' "$ip"
    return 0
}

cmd_start() {
    if _vpn_running; then
        echo '{"error":"already running"}'
        return 1
    fi
    mkdir -p "$ECLIPVPN_TMP"
    if ! _op_begin; then
        echo '{"error":"another lifecycle op in progress"}'
        return 1
    fi
    trap '_op_end' EXIT INT TERM
    _rotate_log
    _ensure_watchdog
    _ensure_cron_state

    # Repair stale DNS state from older code (uci-committed redirect to a
    # not-yet-running sing-box). Without this, a power-yank reboot leaves
    # /etc/resolv.conf → dnsmasq → dead :5354, the subscription URL fails
    # to resolve, and we never fetch servers.json. New code uses
    # /tmp/dnsmasq.d which auto-clears on reboot, but routers upgraded
    # from the old persistence path still need this one-shot cleanup.
    ensure_dns_sane

    local sub_url iface mode
    sub_url=$(get_config_val subscription_url "")
    iface=$(get_config_val interface "br-lan")
    mode=$(get_config_val mode "all_vpn")

    # A subscription source is EITHER the legacy single subscription_url OR the
    # multi-provider subscriptions[] list (the normal case now). Only abort if we
    # have NEITHER and no already-cached servers.json to fall back on. The old
    # check required subscription_url and broke multi-sub-only configs: an empty
    # legacy field made any cold start die here with "subscription_url not
    # configured" — exactly what a Hysteria2 -> VLESS switch hit.
    local n_subs
    n_subs=$(jq '[(.subscriptions // [])[] | select(.enabled != false)] | length' "$ECLIPVPN_CONFIG" 2>/dev/null)
    [ -n "$n_subs" ] || n_subs=0
    if [ ! -f "$ECLIPVPN_TMP/servers.json" ] && [ "$n_subs" -eq 0 ] \
       && { [ -z "$sub_url" ] || [ "$sub_url" = "null" ]; }; then
        flog "ERROR: no subscription configured (no subscriptions[], no subscription_url, no cached servers)"
        echo '{"error":"no subscription configured — add one in Settings"}'
        return 1
    fi
    # Validate the legacy URL format only when it is actually set.
    if [ -n "$sub_url" ] && [ "$sub_url" != "null" ]; then
        case "$sub_url" in
            https://*|http://*) ;;
            *)
                flog "ERROR: subscription_url must start with http:// or https:// (got: ${sub_url%%:*}://...)"
                echo '{"error":"subscription_url must start with http:// or https://"}'
                return 1
                ;;
        esac
    fi
    flog "Starting EclipVPN (mode=$mode)"

    # Step 1: Fetch servers. Cold boot wiped /tmp/servers.json. Prefer an OFFLINE
    # restore (subcache → merge, no network) over update_subscription's fetch:
    # at boot the tunnel isn't up yet, so a direct fetch to the panel can't
    # succeed (blocked WAN, no SOCKS fallback) and just burns ~60s of timeouts
    # before falling back to the same cache anyway. The fresh fetch is deferred to
    # the post-boot `update` (auto-update / manual / watchdog), which runs once the
    # tunnel can reach the panel through SOCKS. First install (no cache) → the
    # merge yields 0 servers → fall back to the online fetch, which must succeed.
    # Refill the failover journal from the persistent mirror before anything
    # else touches /tmp — a reboot wiped incidents.json/last_switch.json, and
    # their whole value is explaining what happened BEFORE the reboot.
    _restore_state
    if [ ! -f "$ECLIPVPN_TMP/servers.json" ]; then
        local count
        _restore_subcache
        count=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
        [ "${count:-0}" -gt 0 ] 2>/dev/null || count=$(update_subscription "$ECLIPVPN_CONFIG")
        [ "$count" -gt 0 ] 2>/dev/null || { echo '{"error":"subscription failed"}'; return 1; }
    fi

    # Step 2: Fetch routing rules. Mode-aware check: a cached dir from the
    # OTHER mode (e.g. config restored with mode=blocklist over an all_vpn
    # run's rules) used to pass the old either-file test and start sing-box
    # with the wrong mode's lists.
    if [ "$mode" = "all_vpn" ]; then
        [ -f "$ECLIPVPN_TMP/rules/ru_domains.list" ] || fetch_rules "$mode"
    else
        [ -f "$ECLIPVPN_TMP/rules/domains.list" ] || fetch_rules "$mode"
    fi

    local selected
    selected=$(get_config_val selected_server 0)
    local total=$(jq 'length' "$ECLIPVPN_TMP/servers.json")
    [ "$selected" -ge "$total" ] && selected=0

    # Tear down any leftover daemon before bring-up. cmd_start is reached as the
    # cold-start fall-through of cmd_restart when `! _vpn_running`; on a Hysteria2
    # -> xray switch that fall-through fires while the OLD hysteria2 sing-box is
    # still alive, and _tunnel_bringup assumes a clean slate — without this the
    # new xray/sing-box collide on :1080/:2154. No-op on a genuine cold start.
    # _kill_all_xray also reaps a legacy pre-rotation xray.json + any staged xray.
    stop_singbox
    _kill_all_xray

    # Steps 3-5: bring up the proxy engine(s) for the selected server.
    # Engine-aware — hysteria2 runs sing-box only; xray protocols run xray +
    # sing-box. _tunnel_bringup leaves daemons stopped on any failure.
    local vpn_ip rc
    vpn_ip=$(_tunnel_bringup "$selected" "$mode"); rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$vpn_ip" ]; then
        flog "ERROR: VPN bring-up failed (rc=$rc)"
        local _fail_name=$(jq -r ".[$selected].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        local _fail_host=$(jq -r ".[$selected].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        _log_incident "switch_failed" "$_fail_host" "$_fail_name" "не удалось поднять туннель при запуске (rc=$rc)"
        case "$rc" in
            1) echo '{"error":"proxy engine failed to start"}' ;;
            2) echo '{"error":"VPN connection failed"}' ;;
            3) echo '{"error":"sing-box failed"}' ;;
            *) echo '{"error":"VPN start failed"}' ;;
        esac
        return 1
    fi
    flog "Tunnel up, VPN IP: $vpn_ip"

    # Step 6: nftables + DNS (LAST)
    flog "Setting up nftables and DNS redirect"
    setup_network 2154 32768 "$iface"

    date +%s > "$ECLIPVPN_TMP/start_time"
    echo "$vpn_ip" > "$ECLIPVPN_TMP/vpn_ip"

    # Mark intent: VPN should be running. Watchdog uses this to revive
    # the tunnel if processes get killed externally (OOM, manual pkill,
    # crash). Distinct from auto_start (which is only consulted at boot).
    update_config '.running_intent = true'

    local server_name=$(jq -r ".[$selected].name" "$ECLIPVPN_TMP/servers.json")
    flog "EclipVPN started: server=$server_name, vpn_ip=$vpn_ip, mode=$mode"
    jq -n --arg s "started" --arg srv "$server_name" --arg ip "$vpn_ip" --arg m "$mode" \
        '{status:$s,server:$srv,vpn_ip:$ip,mode:$m}'
}

cmd_stop() {
    if ! _op_begin; then
        echo '{"error":"another lifecycle op in progress"}'
        return 1
    fi
    trap '_op_end' EXIT INT TERM
    flog "Stopping EclipVPN"
    # Clear intent first — watchdog runs every 20s and would otherwise
    # see processes-down + intent=true and revive the VPN we just stopped.
    update_config '.running_intent = false'
    teardown_network
    stop_singbox
    stop_xray
    rm -f "$ECLIPVPN_TMP/start_time" "$ECLIPVPN_TMP/vpn_ip"
    flog "EclipVPN stopped"
    echo '{"status":"stopped"}'
}

# Reap ANY xray this manager spawned — active or staged, either rotation port
# (xray.1080.json / xray.1081.json), plus the legacy pre-rotation xray.json.
# Used before a cold bring-up / fallback. Does NOT match probe configs
# (probe.*.json) — those clean up after themselves.
_kill_all_xray() {
    for orphan in $(pgrep -f 'xray run -config /tmp/eclipvpn/xray\.' 2>/dev/null); do
        kill -9 "$orphan" 2>/dev/null
    done
    rm -f "$ECLIPVPN_TMP/xray.pid" "$ECLIPVPN_TMP/xray.stage.pid"
}

# Kill a STAGED xray (port $1) cleanly — scoped to its own config path + pidfile
# so it never touches the live xray on the other port.
_stage_drop() { stop_xray "$1" "$ECLIPVPN_TMP/xray.stage.pid"; }

# cmd_restart EXIT/signal cleanup: reap a staged xray if a switch was interrupted
# mid-stage (a successful switch already promoted it via mv, so xray.stage.pid is
# gone and this is a no-op — it never touches the LIVE xray.pid). Then release the
# op-lock. Without this, a SIGTERM/SIGINT (CGI timeout, watchdog OOM-kill) between
# start_xray and the promote would orphan a staged xray on the alternate port.
_restart_cleanup() {
    if [ -f "$ECLIPVPN_TMP/xray.stage.pid" ]; then
        kill -9 "$(cat "$ECLIPVPN_TMP/xray.stage.pid" 2>/dev/null)" 2>/dev/null
        rm -f "$ECLIPVPN_TMP/xray.stage.pid"
    fi
    _op_end
}

# Stage + VERIFY the new exit for server $1 WITHOUT touching the live tunnel.
# $3 = the OLD tunnel's engine (so we stage on a free port). Echoes one of:
#   "xray <port> <ip>"  — a WARM xray left running on <port>, ready to adopt
#   "hysteria2 -"       — reachability verified (sing-box dials it natively on adopt)
# Returns non-zero (leaving nothing running) if the new exit is unreachable.
_stage_exit() {
    local sel="$1" mode="$2" old_engine="$3"
    local new_engine; new_engine=$(_engine_for_protocol "$(_server_protocol "$sel")")
    if [ "$new_engine" = "singbox" ]; then
        # hysteria2 = sing-box native exit (singleton on 1080) — can't keep warm,
        # just verify it answers via a throwaway probe (its own 1082+ port).
        local pr; pr=$(cmd_probe_server "$sel" 2>/dev/null)
        printf '%s' "$pr" | jq -e '.status=="ok"' >/dev/null 2>&1 || return 1
        echo "hysteria2 -"
        return 0
    fi
    local sp; sp=$(_stage_xray_port "$(_active_xray_port)" "$old_engine")
    # Reap any orphaned staged xray a prior interrupted switch may have left on
    # this port, so start_xray below binds fresh and never adopts a stale exit.
    _stage_drop "$sp"
    generate_xray_config "$ECLIPVPN_TMP/servers.json" "$sel" "$ECLIPVPN_TMP/xray.$sp.json" "$sp" || return 1
    start_xray "$ECLIPVPN_TMP/xray.$sp.json" "$sp" "$ECLIPVPN_TMP/xray.stage.pid" || { _stage_drop "$sp"; return 1; }
    local ip; ip=$(test_xray "$sp")
    [ -z "$ip" ] && { _stage_drop "$sp"; return 1; }
    echo "xray $sp $ip"
}

# Cold bring-up fallback when a seamless adopt fails mid-swap (old sing-box
# already stopped). Cleans all xray, cold-starts $1 in mode $2, emits the full
# restart result + state, returns the bring-up rc.
_restart_fallback() {
    local selected="$1" mode="$2"
    flog "WARN: seamless adopt failed — falling back to cold bring-up"
    stop_singbox
    _kill_all_xray
    sleep 1
    local vpn_ip rc
    vpn_ip=$(_tunnel_bringup "$selected" "$mode"); rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$vpn_ip" ]; then
        flog "ERROR: cold bring-up failed after switch (rc=$rc)"
        local fn=$(jq -r ".[$selected].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        local fh=$(jq -r ".[$selected].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        _log_incident "switch_failed" "$fh" "$fn" "не удалось поднять туннель при переключении (rc=$rc)"
        case "$rc" in
            1) echo '{"error":"proxy engine failed to start"}' ;;
            2) echo '{"error":"VPN connection failed"}' ;;
            3) echo '{"error":"sing-box failed"}' ;;
            *) echo '{"error":"VPN restart failed"}' ;;
        esac
        return 1
    fi
    date +%s > "$ECLIPVPN_TMP/start_time"
    echo "$vpn_ip" > "$ECLIPVPN_TMP/vpn_ip"
    update_config '.running_intent = true'
    local sn=$(jq -r --argjson i "$selected" '.[$i].name // ""' "$ECLIPVPN_TMP/servers.json")
    flog "EclipVPN restarted (cold fallback): server=$sn, vpn_ip=$vpn_ip, mode=$mode"
    jq -n --arg s "restarted" --arg srv "$sn" --arg ip "$vpn_ip" --arg m "$mode" \
        '{status:$s,server:$srv,vpn_ip:$ip,mode:$m}'
    return 0
}

cmd_restart() {
    # $1 = "1" to bypass the unchanged-config fast path. UI's manual "Restart"
    # button passes force=1 so a click always physically swaps the daemons —
    # otherwise the user sees a success toast but nothing was actually kicked.
    # Internal callers (set-mode, set-server, watchdog failover, etc.) leave
    # this unset to keep the no-op optimization.
    local force="$1"
    if ! _op_begin; then
        echo '{"error":"another lifecycle op in progress"}'
        return 1
    fi
    trap '_restart_cleanup' EXIT INT TERM
    _ensure_watchdog
    # Soft restart: keeps nftables rules + dnsmasq redirect in place so
    # that during the process-swap gap, traffic fails closed (no internet
    # for clients) instead of leaking direct (~5s of plaintext DNS + traffic).
    # Used by mode change, server switch, watchdog failover, and the UI's
    # "Restart" button. cmd_stop still does the full teardown when the user
    # genuinely wants VPN off.
    # _vpn_live, NOT _vpn_running: a server switch may have just changed
    # selected_server to a DIFFERENT engine (e.g. Hysteria2 -> VLESS). _vpn_running
    # keys off the NEW server's engine (xray) and reports "down" because xray isn't
    # up yet — even though the old tunnel's sing-box is very much alive — so it
    # would wrongly cold-start via cmd_start, which then aborts on the legacy
    # subscription_url guard. _vpn_live ("is ANY daemon up") keeps a live switch on
    # the soft-restart path. (Same reason cmd_set_server uses _vpn_live.)
    if ! _vpn_live; then
        # cmd_start has its own _op_begin — clear ours first to avoid
        # the trap clearing the sentinel mid-operation.
        _op_end
        trap - EXIT INT TERM
        cmd_start
        return $?
    fi

    local selected mode engine
    selected=$(get_config_val selected_server 0)
    mode=$(get_config_val mode "all_vpn")
    local total
    total=$(jq 'length' "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
    [ -n "$total" ] && [ "$selected" -ge "$total" ] && selected=0
    engine=$(_engine_for_protocol "$(_server_protocol "$selected")")

    # No-op fast path: if the freshly-generated configs are identical to what's
    # already running, don't tear processes down. Saves the 5s gap when the UI
    # fires restart for a setting that doesn't actually affect xray/sing-box.
    # Skipped when force=1 (manual UI Restart button) — the user explicitly
    # wants the daemons kicked even if configs match.
    # Engine-aware: a hysteria2 server has no xray.json, so only sing-box is
    # compared in that mode (xray_match stays 1 = "nothing to mismatch").
    local new_xray="$ECLIPVPN_TMP/xray.new.json"
    local new_singbox="$ECLIPVPN_TMP/singbox.new.json"
    # Compare at the ACTIVE socks port (the active xray rotates 1080<->1081):
    # regenerate the candidate configs on the running port so a genuine no-op
    # stays byte-identical and the fast path still fires.
    local cmp_port; cmp_port=$(_active_socks_port)
    generate_singbox_config "$new_singbox" "$mode" "$ECLIPVPN_TMP/servers.json" "$selected" "$cmp_port" 2>/dev/null
    local xray_match=1
    if [ "$engine" = "xray" ]; then
        generate_xray_config "$ECLIPVPN_TMP/servers.json" "$selected" "$new_xray" "$cmp_port" 2>/dev/null
        { [ -s "$new_xray" ] && cmp -s "$new_xray" "$ECLIPVPN_TMP/xray.$cmp_port.json"; } || xray_match=0
    fi
    if [ "$force" != "1" ] && [ "$xray_match" -eq 1 ] && \
       [ -s "$new_singbox" ] && \
       cmp -s "$new_singbox" "$ECLIPVPN_TMP/singbox.json"; then
        rm -f "$new_xray" "$new_singbox"
        # Configs are identical, but is the tunnel actually carrying traffic?
        # If xray hung (process alive, socket dead), watchdog would fix it
        # in 40s, but the user clicking Restart expects an immediate kick.
        # Quick health probe — 4s timeout — falls through to real restart on miss.
        if [ -z "$(test_xray "$cmp_port")" ]; then
            flog "Restart: configs unchanged but tunnel is dead — forcing restart"
            # fallthrough to the real restart below
        else
            local sn vi
            sn=$(jq -r --argjson i "$selected" '.[$i].name // ""' "$ECLIPVPN_TMP/servers.json")
            vi=$(cat "$ECLIPVPN_TMP/vpn_ip" 2>/dev/null)
            # Explicit cleanup before fast-path return. The EXIT trap will
            # eventually fire on script exit, but in ash the timing of
            # function-set traps relative to early returns is fuzzy enough
            # that the watchdog's stale-marker reaper has occasionally
            # raced this. Cheap to be explicit.
            _op_end
            trap - EXIT INT TERM
            jq -n --arg s "unchanged" --arg srv "$sn" --arg ip "$vi" --arg m "$mode" \
                '{status:$s,server:$srv,vpn_ip:$ip,mode:$m}'
            return 0
        fi
    fi
    rm -f "$new_xray" "$new_singbox"

    flog "Switching server (make-before-break)"
    # Old tunnel's engine + active xray port BEFORE the switch — to stage on a
    # free port and drop the right xray afterwards.
    local old_engine="singbox" old_port
    is_xray_running && old_engine="xray"
    old_port=$(_active_xray_port)

    # 1) Stage + VERIFY the new exit WITHOUT touching the live tunnel. Failure
    #    keeps the current connection up — no drop on a dead/unreachable target.
    local stage
    stage=$(_stage_exit "$selected" "$mode" "$old_engine") || {
        flog "Switch aborted: new server unreachable — current tunnel kept"
        local _fn=$(jq -r ".[$selected].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        local _fh=$(jq -r ".[$selected].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        _log_incident "switch_failed" "$_fh" "$_fn" "новый сервер недоступен — оставлен текущий туннель"
        _op_end; trap - EXIT INT TERM
        echo '{"error":"new server unreachable — kept current connection"}'
        return 1
    }
    local stage_eng stage_port
    stage_eng=$(printf '%s' "$stage" | cut -d' ' -f1)
    stage_port=$(printf '%s' "$stage" | cut -d' ' -f2)
    flogd "switch idx=$selected: staged [$stage], old=$old_engine@$old_port"

    # 2) Adopt — the ONLY interruption is one sing-box swap (~1s, deterministic;
    #    the new exit is already warm/verified, so no cold handshake in the gap).
    local vpn_ip=""
    if [ "$stage_eng" = "xray" ]; then
        # New sing-box routes to the WARM staged xray on stage_port. The old xray
        # stays up across the swap, dropped only after the new one verifies.
        generate_singbox_config "$ECLIPVPN_TMP/singbox.json" "$mode" "$ECLIPVPN_TMP/servers.json" "$selected" "$stage_port" \
            || { _stage_drop "$stage_port"; _restart_fallback "$selected" "$mode"; return $?; }
        stop_singbox
        start_singbox "$ECLIPVPN_TMP/singbox.json" \
            || { _stage_drop "$stage_port"; _restart_fallback "$selected" "$mode"; return $?; }
        vpn_ip=$(test_xray "$stage_port")
        [ -z "$vpn_ip" ] && { _stage_drop "$stage_port"; _restart_fallback "$selected" "$mode"; return $?; }
        # Promote: drop the OLD xray FIRST (xray.pid still holds its pid), then
        # hand the staged xray's pidfile over and record the new active port.
        [ "$old_engine" = "xray" ] && stop_xray "$old_port"
        mv -f "$ECLIPVPN_TMP/xray.stage.pid" "$ECLIPVPN_TMP/xray.pid" 2>/dev/null
        echo "$stage_port" > "$ECLIPVPN_TMP/xray_port"
    else
        # hysteria2 destination: sing-box IS the exit (singleton on 1080) and
        # can't be warmed ahead — verify-before-commit only. Free the old xray's
        # port BEFORE the new hy2 sing-box claims 1080.
        generate_singbox_config "$ECLIPVPN_TMP/singbox.json" "$mode" "$ECLIPVPN_TMP/servers.json" "$selected" \
            || { _restart_fallback "$selected" "$mode"; return $?; }
        stop_singbox
        [ "$old_engine" = "xray" ] && stop_xray "$old_port"
        rm -f "$ECLIPVPN_TMP/xray_port"
        start_singbox "$ECLIPVPN_TMP/singbox.json" \
            || { _restart_fallback "$selected" "$mode"; return $?; }
        vpn_ip=$(test_xray 1080)
        [ -z "$vpn_ip" ] && { _restart_fallback "$selected" "$mode"; return $?; }
    fi

    flog "Tunnel switched (make-before-break) -> $vpn_ip (engine=$stage_eng port=${stage_port:-1080})"
    date +%s > "$ECLIPVPN_TMP/start_time"
    echo "$vpn_ip" > "$ECLIPVPN_TMP/vpn_ip"

    # Restart implies user wants VPN running — keep intent flag in sync.
    # Without this a soft restart (UI button, set-server, set-mode, watchdog
    # failover) wouldn't carry the intent, and an external kill afterwards
    # wouldn't trigger auto-recovery.
    update_config '.running_intent = true'

    local server_name=$(jq -r --argjson i "$selected" '.[$i].name // ""' "$ECLIPVPN_TMP/servers.json")
    flog "EclipVPN restarted: server=$server_name, vpn_ip=$vpn_ip, mode=$mode"
    jq -n --arg s "restarted" --arg srv "$server_name" --arg ip "$vpn_ip" --arg m "$mode" \
        '{status:$s,server:$srv,vpn_ip:$ip,mode:$m}'
}

cmd_status() {
    # Polled from UI every 5s — kept cheap.
    # Single jq pass: --slurpfile reads config + servers.json once each,
    # everything else (running, vpn_ip, uptime, etc.) comes via --argjson/--arg.
    local running="false" uptime=0 vpn_ip=""
    if _vpn_running; then
        running="true"
        [ -f "$ECLIPVPN_TMP/start_time" ] && {
            local st=$(cat "$ECLIPVPN_TMP/start_time")
            uptime=$(($(date +%s) - st))
        }
        [ -f "$ECLIPVPN_TMP/vpn_ip" ] && vpn_ip=$(cat "$ECLIPVPN_TMP/vpn_ip")
    fi

    # Self-heal an empty pool. After a cold boot with no WAN, init.d skips
    # autostart entirely ("Network not ready"), so cmd_start's offline restore
    # (subcache → merge) never ran and the UI would show subscriptions with
    # ZERO servers until the next start/update — which can't fetch anyway on a
    # whitelist-only uplink. Rebuild the pool from the persistent mirrors right
    # here: offline, no fetch, and a no-op whenever servers.json already exists.
    [ -s "$ECLIPVPN_TMP/servers.json" ] || { _restore_subcache; _merge_sub_pool "$ECLIPVPN_CONFIG" >/dev/null 2>&1; }
    # /tmp was wiped by the reboot — refill the failover journal from the
    # persistent mirror so the UI shows history instead of an empty list.
    _restore_state

    # Read the pool via --slurpfile (a file path), NOT --argjson (a shell
    # arg): the Linux kernel caps a single execve() argument at 128KiB
    # (MAX_ARG_STRLEN), and a merged pool past ~150-200 servers blows through
    # that — jq then dies with a silent-ish "Argument list too long" (E2BIG)
    # on EVERY /status poll, so the UI shows zero servers even though the
    # pool is fine on disk (hit live at 330 servers / 193KB, 2026-09-14).
    # --slurpfile wraps the file's content in an array, hence $srv[0] below.
    local srv_file="$ECLIPVPN_TMP/servers.json"
    if [ ! -s "$srv_file" ]; then
        srv_file="$ECLIPVPN_TMP/.status_servers_empty.json"
        mkdir -p "$ECLIPVPN_TMP"
        echo '[]' > "$srv_file"
    fi

    local device_count=0
    [ -f /tmp/dhcp.leases ] && device_count=$(wc -l < /tmp/dhcp.leases)

    # Read meta-files via jq so a corrupt/half-written file (truncated by
    # power loss on /tmp) doesn't make --argjson choke and break the whole
    # status response.
    local last_switch='null'
    [ -f "$ECLIPVPN_TMP/last_switch.json" ] && \
        last_switch=$(jq '.' "$ECLIPVPN_TMP/last_switch.json" 2>/dev/null || echo null)
    local last_update='null'
    [ -f "$ECLIPVPN_TMP/last_update.json" ] && \
        last_update=$(jq '.' "$ECLIPVPN_TMP/last_update.json" 2>/dev/null || echo null)
    local sub_meta='null'
    [ -f "$ECLIPVPN_TMP/subscription_meta.json" ] && \
        sub_meta=$(jq '.' "$ECLIPVPN_TMP/subscription_meta.json" 2>/dev/null || echo null)

    jq -n \
        --slurpfile cfg "$ECLIPVPN_CONFIG" \
        --slurpfile srvfile "$srv_file" \
        --argjson running "$running" \
        --argjson uptime "$uptime" \
        --arg vpn_ip "$vpn_ip" \
        --argjson devices "$device_count" \
        --argjson last_switch "$last_switch" \
        --argjson last_update "$last_update" \
        --argjson sub_meta "$sub_meta" \
        '$cfg[0] as $c |
         ($srvfile[0] // []) as $srv |
         ($c.selected_server // 0) as $sel |
         (($c.muted_servers // "") | split(",") | map(select(length>0))) as $mtoks |
         {running:$running,
          server: (if $running then ($srv[$sel].name // "") else "" end),
          uptime:$uptime,
          selected: $sel,
          # muted is computed HERE, server-side, not mirrored in the UI the way
          # isMeteredServer() mirrors _is_metered_server — that duplication is
          # already a standing bug source, and this list is user data that only
          # the router has. contains(), never test(): no Oniguruma on the router.
          servers: ($srv | map(. as $s | {name, host, port, protocol:(.protocol // "vless"),
                                sub_id:(.sub_id // ""), sub_name:(.sub_name // ""),
                                muted: ($mtoks | any(. as $t | ($s.name // "") | contains($t)))})),
          muted_servers: ($c.muted_servers // ""),
          subscription_url: ($c.subscription_url // ""),
          subscriptions: ($c.subscriptions // []),
          vpn_ip:$vpn_ip,
          mode: ($c.mode // "all_vpn"),
          devices:$devices,
          auto_start: ($c.auto_start | if . == false then false else true end),
          auto_mode: ($c.auto_mode // false),
          # Behaviour toggles the UI must be able to SHOW, not just store: a
          # user who turns automatic failover off gets a tunnel that no longer
          # self-heals, and until this was exposed nothing in /status or the UI
          # said so. Defaults matter here — `// true` is WRONG for a key whose
          # default is true, because jq treats false as falsy and would flip a
          # deliberate false back to true (same trap as auto_start).
          auto_failover: ($c.auto_failover | if . == false then false else true end),
          tput_guard: ($c.tput_guard | if . == false then false else true end),
          full_tunnel: ($c.full_tunnel // false),
          net_check_switch: ($c.net_check_switch | if . == false then false else true end),
          running_intent: ($c.running_intent // false),
          device_rules: ($c.device_rules // {}),
          last_switch:$last_switch,
          last_update:$last_update,
          subscription_meta:$sub_meta}'
}
