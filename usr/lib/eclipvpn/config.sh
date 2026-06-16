#!/bin/ash
# EclipVPN — config writes: set-config, schedule, auto-update, backup/restore, device routing, wifi.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers, all
# resolved at call time, so source order among the libs does not matter.

cmd_set_config() {
    local key="$1" value="$2"
    [ -z "$key" ] || [ -z "$value" ] && { echo '{"error":"missing key or value"}'; return 1; }
    # Whitelist allowed keys
    case "$key" in
        subscription_url|interface|mode|auto_start|selected_server|blocklist_source|auto_mode|tput_guard|tput_min_kbps|wan_mtu) ;;
        *) echo '{"error":"invalid key"}'; return 1 ;;
    esac
    # mode change needs to wipe rules and refetch them — same dance as
    # cmd_set_mode. Without this delegation, `set-config?key=mode&value=...`
    # via CGI saves the new mode to config but leaves the old mode's rules
    # in place; sing-box restarts with the wrong list (e.g. blocklist mode
    # without domains.list → all traffic goes direct).
    [ "$key" = "mode" ] && { cmd_set_mode "$value"; return $?; }
    # subscription_url is legacy (single sub). Route it through the multi-sub
    # manager so it becomes/updates the primary subscriptions[] entry (and
    # triggers a refresh) instead of writing a dangling key the merge ignores.
    [ "$key" = "subscription_url" ] && { cmd_sub add "$value"; return $?; }
    # blocklist_source: validate value at the boundary (CGI lets any
    # `[a-zA-Z0-9_-]` through, so a malformed value would silently fall
    # through to the default branch in _fetch_blocklist_domains).
    if [ "$key" = "blocklist_source" ]; then
        case "$value" in curated|full) ;; *) echo '{"error":"blocklist_source must be curated or full"}'; return 1 ;; esac
    fi
    # Boolean keys: store as JSON true/false instead of "true"/"false" string,
    # so cmd_status's `// true` defaults work and the UI gets a real bool.
    case "$key" in
        auto_start|auto_mode|tput_guard)
            local bv
            case "$value" in
                true|1|on|yes) bv=true ;;
                *) bv=false ;;
            esac
            update_config '.[$k] = $v' --arg k "$key" --argjson v "$bv" || { echo '{"error":"save failed"}'; return 1; }
            ;;
        selected_server|tput_min_kbps|wan_mtu)
            case "$value" in ''|*[!0-9]*) echo '{"error":"'"$key"' must be numeric"}'; return 1 ;; esac
            # wan_mtu: 0 = leave the interface alone; otherwise clamp to a
            # sane range — _apply_wan_mtu would happily set MTU 100 and
            # take the whole WAN down.
            if [ "$key" = "wan_mtu" ] && [ "$value" != "0" ]; then
                if [ "$value" -lt 576 ] || [ "$value" -gt 1500 ]; then
                    echo '{"error":"wan_mtu must be 0 (off) or 576-1500"}'; return 1
                fi
            fi
            update_config '.[$k] = $v' --arg k "$key" --argjson v "$value" || { echo '{"error":"save failed"}'; return 1; }
            ;;
        *)
            update_config '.[$k] = $v' --arg k "$key" --arg v "$value" || { echo '{"error":"save failed"}'; return 1; }
            ;;
    esac
    jq -n --arg k "$key" '{status:"saved",key:$k}'
}

cmd_schedule() {
    local action="$1" on_time="$2" off_time="$3"
    case "$action" in
        set)
            [ -z "$on_time" ] || [ -z "$off_time" ] && { echo '{"error":"need on_time and off_time"}'; return 1; }
            # Reject HH:MM with hour 24-29 (the CGI's [0-2][0-9] pattern lets
            # those through); cron would silently never fire on them.
            local _t
            for _t in "$on_time" "$off_time"; do
                case "$_t" in
                    [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
                    *) echo '{"error":"time must be HH:MM in 00:00-23:59"}'; return 1 ;;
                esac
            done
            update_config '.schedule = {enabled:true, on:$on, off:$off}' \
                --arg on "$on_time" --arg off "$off_time" || { echo '{"error":"save failed"}'; return 1; }
            _setup_cron
            jq -n --arg on "$on_time" --arg off "$off_time" '{status:"schedule set",on:$on,off:$off}'
            ;;
        disable)
            update_config '.schedule.enabled = false' || { echo '{"error":"save failed"}'; return 1; }
            _remove_cron
            echo '{"status":"schedule disabled"}'
            ;;
        *)
            local sched=$(jq '.schedule // {enabled:false}' "$ECLIPVPN_CONFIG")
            echo "$sched"
            ;;
    esac
}
_setup_cron() {
    _remove_cron
    local on_time off_time
    on_time=$(jq -r '.schedule.on // "07:00"' "$ECLIPVPN_CONFIG")
    off_time=$(jq -r '.schedule.off // "23:00"' "$ECLIPVPN_CONFIG")
    # Re-validate HH:MM. The CGI checks at the boundary, but cmd_restore
    # writes .schedule from a backup blob — a crafted backup could put
    # "07:00; rm -rf /" in here and that string would otherwise land
    # straight into a crontab line, executed by root.
    # Strict 00-23 hour (NOT [0-2][0-9], which accepts 24-29) — a restored backup
    # with "25:00" would otherwise write a cron line crond never fires while the
    # UI still shows the schedule active.
    case "$on_time"  in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) flog "ERROR: invalid schedule.on '$on_time' — cron not installed"; return 1 ;; esac
    case "$off_time" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) flog "ERROR: invalid schedule.off '$off_time' — cron not installed"; return 1 ;; esac
    local on_h=${on_time%%:*} on_m=${on_time##*:}
    local off_h=${off_time%%:*} off_m=${off_time##*:}
    (crontab -l 2>/dev/null; echo "$on_m $on_h * * * /usr/bin/eclipvpn start >/dev/null 2>&1 #eclipvpn") | crontab -
    (crontab -l 2>/dev/null; echo "$off_m $off_h * * * /usr/bin/eclipvpn stop >/dev/null 2>&1 #eclipvpn") | crontab -
}
_remove_cron() {
    # Anchored: a bare "#eclipvpn" substring match also swallowed the
    # auto-update line ("#eclipvpn-update"), so every schedule set/disable
    # silently killed the nightly refresh while config still said enabled.
    crontab -l 2>/dev/null | grep -v "#eclipvpn$" | crontab -
}
# Reconcile crontab with config.json. Two cases this self-heals:
#   - `restore` onto a fresh router: schedule/auto_update arrive as config
#     flags, but no crontab lines exist — both features look enabled in the
#     UI while nothing ever fires;
#   - migration from a pre-rename install: its cron lines point at the
#     deleted /usr/bin/flowvpn binary.
# Cheap (one crontab read + two jq calls), called from cmd_start (covers
# boot and every manual start) and from cmd_restore.
_ensure_cron_state() {
    local cur
    cur=$(crontab -l 2>/dev/null)
    case "$cur" in
        *"/usr/bin/flowvpn"*)
            printf '%s\n' "$cur" | grep -v "/usr/bin/flowvpn " | crontab -
            cur=$(crontab -l 2>/dev/null)
            ;;
    esac
    if [ "$(jq -r '.schedule.enabled // false' "$ECLIPVPN_CONFIG" 2>/dev/null)" = "true" ]; then
        printf '%s\n' "$cur" | grep -q "#eclipvpn$" || _setup_cron
    else
        printf '%s\n' "$cur" | grep -q "#eclipvpn$" && _remove_cron
    fi
    if [ "$(jq -r '.auto_update // false' "$ECLIPVPN_CONFIG" 2>/dev/null)" = "true" ]; then
        printf '%s\n' "$cur" | grep -q "#eclipvpn-update$" || _setup_auto_update_cron
    else
        printf '%s\n' "$cur" | grep -q "#eclipvpn-update$" && _remove_auto_update_cron
    fi
    # Watchdog supervision line — installed unconditionally (the command
    # self-gates on running_intent, so it's inert after a deliberate stop).
    # Marker #eclipvpn-watch: the anchored greps elsewhere (#eclipvpn$ in
    # _remove_cron, #eclipvpn-update in _remove_auto_update_cron) can't
    # collide with it.
    printf '%s\n' "$cur" | grep -q "#eclipvpn-watch$" || \
        (crontab -l 2>/dev/null; echo "*/5 * * * * /usr/bin/eclipvpn ensure-watchdog >/dev/null 2>&1 #eclipvpn-watch") | crontab -
    return 0
}
cmd_auto_update() {
    local action="$1"
    case "$action" in
        enable)
            update_config '.auto_update = true'
            _setup_auto_update_cron
            echo '{"status":"auto-update enabled"}'
            ;;
        disable)
            update_config '.auto_update = false'
            _remove_auto_update_cron
            echo '{"status":"auto-update disabled"}'
            ;;
        *)
            jq '{auto_update: (.auto_update // false)}' "$ECLIPVPN_CONFIG"
            ;;
    esac
}
_setup_auto_update_cron() {
    _remove_auto_update_cron
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/eclipvpn update >/dev/null 2>&1 #eclipvpn-update") | crontab -
}
_remove_auto_update_cron() {
    crontab -l 2>/dev/null | grep -v "#eclipvpn-update" | crontab -
}
cmd_backup() {
    local direct_domains="" vpn_domains=""
    [ -f /etc/eclipvpn/direct_domains.txt ] && direct_domains=$(cat /etc/eclipvpn/direct_domains.txt)
    [ -f /etc/eclipvpn/vpn_domains.txt ] && vpn_domains=$(cat /etc/eclipvpn/vpn_domains.txt)
    jq -n --argjson config "$(cat $ECLIPVPN_CONFIG)" \
        --arg direct "$direct_domains" --arg vpn "$vpn_domains" \
        '{config:$config, direct_domains:$direct, vpn_domains:$vpn, version:"v4"}'
}
cmd_restore() {
    local data
    if [ -n "$1" ]; then
        data="$1"
    else
        data=$(cat)
    fi
    [ -z "$data" ] && { echo '{"error":"no data"}'; return 1; }
    # Validate JSON structure before applying — prevents writing garbage to config
    if ! printf '%s' "$data" | jq -e '.config' >/dev/null 2>&1; then
        echo '{"error":"invalid backup format"}'; return 1
    fi
    # Route the config through update_config/save_config so we get atomic mv +
    # chmod 600 + JSON re-validation. A raw `>` redirect would leave a world-
    # readable file with the subscription URL on partial writes (OOM, reboot).
    local cfg
    cfg=$(printf '%s' "$data" | jq -c '.config')
    # Full replace, not a key edit — but still routed through update_config so
    # it takes the config lock: a watchdog selected_server write landing between
    # a bare read and save would otherwise silently drop the whole restore. The
    # jq program ignores the current config and emits the backup's verbatim;
    # save_config re-validates + atomically mv's it.
    update_config '$repl' --argjson repl "$cfg" || { echo '{"error":"invalid config in backup"}'; return 1; }

    # Domain lists are merged into ru_domains.list / vpn_domains.list at
    # the next mode/start. A backup blob is untrusted input, so filter to
    # the same shape the CGI's `domain` validator accepts: no leading dot,
    # no consecutive dots, only [a-zA-Z0-9.*_/-]. The slash is deliberate —
    # the direct list holds IP-CIDR entries like 192.168.0.0/24 (the CGI
    # allows them); the old slash-less filter silently dropped them on
    # restore. Anything else (control chars, metacharacters) is dropped.
    local re='^[a-zA-Z0-9*][a-zA-Z0-9.*_/-]*$'
    printf '%s' "$data" | jq -r '.direct_domains // ""' \
        | tr -d '\r' | grep -v '\.\.' | grep -E "$re" \
        > /etc/eclipvpn/direct_domains.txt 2>/dev/null
    printf '%s' "$data" | jq -r '.vpn_domains // ""' \
        | tr -d '\r' | grep -v '\.\.' | grep -E "$re" \
        > /etc/eclipvpn/vpn_domains.txt 2>/dev/null
    # The restored config may carry schedule/auto_update flags from the old
    # router — re-arm crontab to match, or both silently stay inert here.
    _ensure_cron_state

    # Apply immediately. The old code returned "restored" while the live tunnel
    # kept the PREVIOUS config until a manual restart — yet the UI dialog
    # promised "VPN перезапустится". If the VPN is running, a soft restart
    # picks up the restored mode/device_rules. servers.json is intentionally
    # NOT in a backup, so on a fresh router this stays down until the user
    # presses Start (cmd_start fetches the subscription then) — `applied`
    # tells the UI which case happened so it can prompt honestly.
    local applied=false
    if _vpn_running && cmd_restart >/dev/null 2>&1; then
        applied=true
    fi
    jq -n --argjson a "$applied" '{status:"restored", applied:$a}'
}
_validate_ipv4() {
    # Returns 0 if $1 is a valid dotted-quad with octets 0-255, else 1.
    local ip="$1"
    case "$ip" in *[!0-9.]*|*..*|.*|*.) return 1;; esac
    local IFS=.; set -- $ip; unset IFS
    [ $# -eq 4 ] || return 1
    for o in "$@"; do
        case "$o" in ''|*[!0-9]*) return 1;; esac
        [ "$o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}
# Accept "AA:BB:CC:DD:EE:FF" form (case-insensitive). Returns the MAC
# normalized to uppercase so config storage is consistent.
_normalize_mac() {
    local m="$1"
    case "$m" in
        [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F])
            printf '%s' "$m" | tr 'a-f' 'A-F'
            return 0
            ;;
    esac
    return 1
}
cmd_set_device_route() {
    local id="$1" route="$2"
    [ -z "$id" ] || [ -z "$route" ] && { echo '{"error":"need id (ip or mac) and route (vpn/direct)"}'; return 1; }
    case "$route" in vpn|direct) ;; *) echo '{"error":"route must be vpn or direct"}'; return 1;; esac
    # Accept either IPv4 or MAC. MAC is preferred — survives DHCP changes.
    local mac
    if mac=$(_normalize_mac "$id"); then
        id="$mac"
    elif ! _validate_ipv4 "$id"; then
        echo '{"error":"id must be a valid IPv4 or MAC address"}'; return 1
    fi
    update_config '.device_rules[$id] = $r' --arg id "$id" --arg r "$route"
    # Rebuild nftables if running
    if is_singbox_running; then
        local iface=$(get_config_val interface "br-lan")
        # Serialize the nft delete+rebuild against a watchdog failover (cmd_start
        # also rebuilds the table) — two concurrent rebuilds leave a half-built
        # table. The rule is already saved; if the op-lock is held, skip the
        # in-place rebuild (it applies on the next (re)start) rather than race.
        if _op_begin; then setup_network 2154 32768 "$iface"; _op_end; fi
    fi
    echo "{\"status\":\"device route set\",\"id\":\"$id\",\"route\":\"$route\"}"
}
cmd_remove_device_route() {
    local id="$1"
    [ -z "$id" ] && { echo '{"error":"need id"}'; return 1; }
    local mac
    if mac=$(_normalize_mac "$id"); then
        id="$mac"
    elif ! _validate_ipv4 "$id"; then
        echo '{"error":"id must be a valid IPv4 or MAC address"}'; return 1
    fi
    update_config 'del(.device_rules[$id])' --arg id "$id"
    if is_singbox_running; then
        local iface=$(get_config_val interface "br-lan")
        # Serialize the nft delete+rebuild against a watchdog failover (cmd_start
        # also rebuilds the table) — two concurrent rebuilds leave a half-built
        # table. The rule is already saved; if the op-lock is held, skip the
        # in-place rebuild (it applies on the next (re)start) rather than race.
        if _op_begin; then setup_network 2154 32768 "$iface"; _op_end; fi
    fi
    echo "{\"status\":\"device route removed\",\"id\":\"$id\"}"
}
cmd_set_wifi() {
    local ssid="$1" password="$2"
    [ -z "$password" ] && { echo '{"error":"missing password"}'; return 1; }
    # WPA2-PSK keys must be 8-63 chars. Anything shorter/longer makes hostapd
    # refuse to bring the radio up → total Wi-Fi loss, and you may be
    # administering the router over that very Wi-Fi. Reject before committing.
    local _plen=${#password}
    if [ "$_plen" -lt 8 ] || [ "$_plen" -gt 63 ]; then
        echo '{"error":"password must be 8-63 characters"}'; return 1
    fi
    uci set wireless.default_radio0.encryption="psk2"
    uci set wireless.default_radio0.key="$password"
    uci set wireless.default_radio1.encryption="psk2"
    uci set wireless.default_radio1.key="$password"
    [ -n "$ssid" ] && {
        uci set wireless.default_radio0.ssid="${ssid}_2"
        uci set wireless.default_radio1.ssid="${ssid}_5"
    }
    uci commit wireless
    wifi reload >/dev/null 2>&1 &
    echo '{"status":"wifi updated"}'
}
