#!/bin/ash
# EclipVPN — lifecycle: start / stop / restart / status.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers, all
# resolved at call time, so source order among the libs does not matter.

cmd_start() {
    if is_xray_running && is_singbox_running; then
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

    # Fail fast and clearly on bad subscription URL — don't burn time on
    # update_subscription's curl timeout to discover an obvious config error.
    if [ -z "$sub_url" ] || [ "$sub_url" = "null" ]; then
        flog "ERROR: subscription_url not configured"
        echo '{"error":"subscription_url not configured — set it in Settings"}'
        return 1
    fi
    case "$sub_url" in
        https://*|http://*) ;;
        *)
            flog "ERROR: subscription_url must start with http:// or https:// (got: ${sub_url%%:*}://...)"
            echo '{"error":"subscription_url must start with http:// or https://"}'
            return 1
            ;;
    esac
    flog "Starting EclipVPN (mode=$mode)"

    # Step 1: Fetch servers
    if [ ! -f "$ECLIPVPN_TMP/servers.json" ]; then
        local count
        count=$(update_subscription "$ECLIPVPN_CONFIG")
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

    # Step 3: Start xray
    flog "Starting xray (server index=$selected)"
    generate_xray_config "$ECLIPVPN_TMP/servers.json" "$selected" "$ECLIPVPN_TMP/xray.json"
    start_xray "$ECLIPVPN_TMP/xray.json" || { flog "ERROR: xray failed to start"; echo '{"error":"xray failed"}'; return 1; }

    # Step 4: Verify xray
    local vpn_ip
    vpn_ip=$(test_xray)
    if [ -z "$vpn_ip" ]; then
        flog "ERROR: VPN connection test failed"
        local _fail_name=$(jq -r ".[$selected].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        local _fail_host=$(jq -r ".[$selected].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        _log_incident "switch_failed" "$_fail_host" "$_fail_name" "test_xray не прошёл при запуске"
        stop_xray
        echo '{"error":"VPN connection failed"}'
        return 1
    fi
    flog "xray connected, VPN IP: $vpn_ip"

    # Step 5: Start sing-box
    flog "Starting sing-box (mode=$mode)"
    generate_singbox_config "$ECLIPVPN_TMP/singbox.json" 1080 "$mode"
    start_singbox "$ECLIPVPN_TMP/singbox.json"
    if [ $? -ne 0 ]; then
        flog "ERROR: sing-box failed to start"
        stop_xray
        echo '{"error":"sing-box failed"}'
        return 1
    fi
    flog "sing-box started"

    # Step 6: nftables + DNS (LAST)
    flog "Setting up nftables and DNS redirect"
    setup_network 2154 32768 "$iface"

    date +%s > "$ECLIPVPN_TMP/start_time"
    echo "$vpn_ip" > "$ECLIPVPN_TMP/vpn_ip"

    # Mark intent: VPN should be running. Watchdog uses this to revive
    # the tunnel if processes get killed externally (OOM, manual pkill,
    # crash). Distinct from auto_start (which is only consulted at boot).
    local cfg_tmp
    cfg_tmp=$(jq '.running_intent = true' "$ECLIPVPN_CONFIG")
    save_config "$cfg_tmp"

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
    local cfg_tmp
    cfg_tmp=$(jq '.running_intent = false' "$ECLIPVPN_CONFIG")
    save_config "$cfg_tmp"
    teardown_network
    stop_singbox
    stop_xray
    rm -f "$ECLIPVPN_TMP/start_time" "$ECLIPVPN_TMP/vpn_ip"
    flog "EclipVPN stopped"
    echo '{"status":"stopped"}'
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
    trap '_op_end' EXIT INT TERM
    _ensure_watchdog
    # Soft restart: keeps nftables rules + dnsmasq redirect in place so
    # that during the process-swap gap, traffic fails closed (no internet
    # for clients) instead of leaking direct (~5s of plaintext DNS + traffic).
    # Used by mode change, server switch, watchdog failover, and the UI's
    # "Restart" button. cmd_stop still does the full teardown when the user
    # genuinely wants VPN off.
    if ! is_xray_running && ! is_singbox_running; then
        # cmd_start has its own _op_begin — clear ours first to avoid
        # the trap clearing the sentinel mid-operation.
        _op_end
        trap - EXIT INT TERM
        cmd_start
        return $?
    fi

    local selected mode
    selected=$(get_config_val selected_server 0)
    mode=$(get_config_val mode "all_vpn")
    local total
    total=$(jq 'length' "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
    [ -n "$total" ] && [ "$selected" -ge "$total" ] && selected=0

    # No-op fast path: if the freshly-generated configs are identical to what's
    # already running, don't tear processes down. Saves the 5s gap when the UI
    # fires restart for a setting that doesn't actually affect xray/sing-box.
    # Skipped when force=1 (manual UI Restart button) — the user explicitly
    # wants the daemons kicked even if configs match.
    local new_xray="$ECLIPVPN_TMP/xray.new.json"
    local new_singbox="$ECLIPVPN_TMP/singbox.new.json"
    generate_xray_config "$ECLIPVPN_TMP/servers.json" "$selected" "$new_xray" 2>/dev/null
    generate_singbox_config "$new_singbox" 1080 "$mode" 2>/dev/null
    if [ "$force" != "1" ] && \
       [ -s "$new_xray" ] && [ -s "$new_singbox" ] && \
       cmp -s "$new_xray" "$ECLIPVPN_TMP/xray.json" && \
       cmp -s "$new_singbox" "$ECLIPVPN_TMP/singbox.json"; then
        rm -f "$new_xray" "$new_singbox"
        # Configs are identical, but is the tunnel actually carrying traffic?
        # If xray hung (process alive, socket dead), watchdog would fix it
        # in 40s, but the user clicking Restart expects an immediate kick.
        # Quick health probe — 4s timeout — falls through to real restart on miss.
        if [ -z "$(test_xray)" ]; then
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

    flog "Restarting EclipVPN (soft — network rules preserved)"
    stop_singbox
    stop_xray
    sleep 1

    flog "Starting xray (server index=$selected)"
    generate_xray_config "$ECLIPVPN_TMP/servers.json" "$selected" "$ECLIPVPN_TMP/xray.json"
    start_xray "$ECLIPVPN_TMP/xray.json" || { flog "ERROR: xray failed to start"; echo '{"error":"xray failed"}'; return 1; }

    local vpn_ip
    vpn_ip=$(test_xray)
    if [ -z "$vpn_ip" ]; then
        flog "ERROR: VPN connection test failed after restart"
        local _fail_name=$(jq -r ".[$selected].name // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        local _fail_host=$(jq -r ".[$selected].host // \"\"" "$ECLIPVPN_TMP/servers.json" 2>/dev/null)
        _log_incident "switch_failed" "$_fail_host" "$_fail_name" "test_xray не прошёл при переключении"
        stop_xray
        echo '{"error":"VPN connection failed"}'
        return 1
    fi
    flog "xray reconnected, VPN IP: $vpn_ip"

    generate_singbox_config "$ECLIPVPN_TMP/singbox.json" 1080 "$mode"
    start_singbox "$ECLIPVPN_TMP/singbox.json" || { flog "ERROR: sing-box failed"; stop_xray; echo '{"error":"sing-box failed"}'; return 1; }
    flog "sing-box restarted"

    date +%s > "$ECLIPVPN_TMP/start_time"
    echo "$vpn_ip" > "$ECLIPVPN_TMP/vpn_ip"

    # Restart implies user wants VPN running — keep intent flag in sync.
    # Without this a soft restart (UI button, set-server, set-mode, watchdog
    # failover) wouldn't carry the intent, and an external kill afterwards
    # wouldn't trigger auto-recovery.
    local cfg_tmp
    cfg_tmp=$(jq '.running_intent = true' "$ECLIPVPN_CONFIG")
    save_config "$cfg_tmp"

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
    if is_xray_running && is_singbox_running; then
        running="true"
        [ -f "$ECLIPVPN_TMP/start_time" ] && {
            local st=$(cat "$ECLIPVPN_TMP/start_time")
            uptime=$(($(date +%s) - st))
        }
        [ -f "$ECLIPVPN_TMP/vpn_ip" ] && vpn_ip=$(cat "$ECLIPVPN_TMP/vpn_ip")
    fi

    local servers_raw='[]'
    [ -f "$ECLIPVPN_TMP/servers.json" ] && servers_raw=$(cat "$ECLIPVPN_TMP/servers.json")

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
        --argjson running "$running" \
        --argjson uptime "$uptime" \
        --argjson srv "$servers_raw" \
        --arg vpn_ip "$vpn_ip" \
        --argjson devices "$device_count" \
        --argjson last_switch "$last_switch" \
        --argjson last_update "$last_update" \
        --argjson sub_meta "$sub_meta" \
        '$cfg[0] as $c |
         ($c.selected_server // 0) as $sel |
         {running:$running,
          server: (if $running then ($srv[$sel].name // "") else "" end),
          uptime:$uptime,
          selected: $sel,
          servers: ($srv | map({name, host, port})),
          subscription_url: ($c.subscription_url // ""),
          vpn_ip:$vpn_ip,
          mode: ($c.mode // "all_vpn"),
          devices:$devices,
          auto_start: ($c.auto_start | if . == false then false else true end),
          auto_mode: ($c.auto_mode // false),
          running_intent: ($c.running_intent // false),
          device_rules: ($c.device_rules // {}),
          last_switch:$last_switch,
          last_update:$last_update,
          subscription_meta:$sub_meta}'
}
