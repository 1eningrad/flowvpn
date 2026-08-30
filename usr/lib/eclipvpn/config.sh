#!/bin/ash
# EclipVPN — config writes: set-config, schedule, auto-update, backup/restore, device routing, wifi.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers, all
# resolved at call time, so source order among the libs does not matter.

cmd_set_config() {
    local key="$1" value="$2"
    [ -z "$key" ] || [ -z "$value" ] && { _err "set-config: missing key or value"; return 1; }
    # Whitelist allowed keys
    case "$key" in
        subscription_url|interface|mode|auto_start|selected_server|blocklist_source|auto_mode|tput_guard|tput_min_kbps|wan_mtu|log_debug|singbox_loglevel|server_filter|muted_servers|full_tunnel|auto_failover|dns_direct_servers|dns_overrides) ;;
        *) _err "set-config: invalid key '$key'"; return 1 ;;
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
    # selected_server must go through cmd_set_server: it bounds-checks the index
    # against servers.json, runs the make-before-break switch, and rolls back on
    # a failed switch. A bare set-config write skips all that and would leave a
    # stale/out-of-range index in the live config (this key is CGI-reachable).
    [ "$key" = "selected_server" ] && { cmd_set_server "$value"; return $?; }
    # blocklist_source: validate value at the boundary (CGI lets any
    # `[a-zA-Z0-9_-]` through, so a malformed value would silently fall
    # through to the default branch in _fetch_blocklist_domains).
    if [ "$key" = "blocklist_source" ]; then
        case "$value" in curated|full) ;; *) _err "blocklist_source must be curated or full"; return 1 ;; esac
    fi
    # singbox_loglevel: info (default) drives the UI "Журнал" flow panel
    # (Все/VPN/Direct/DNS read singbox.log outbound/dns lines); warn shrinks the
    # raw log but empties those tabs. log_debug toggles EclipVPN's own DEBUG
    # trace (flogd) — both changeable without a redeploy.
    if [ "$key" = "singbox_loglevel" ]; then
        case "$value" in warn|info|error|debug) ;; *) _err "singbox_loglevel must be warn|info|error|debug"; return 1 ;; esac
    fi
    # server_filter: comma-separated case-sensitive NAME substrings; only servers
    # whose name contains one of them stay in the merged pool (e.g. "WL" keeps
    # only the whitelist nodes that work on a network where the rest are dead, so
    # probe-driven failover/auto-select stop wasting minutes on unreachable
    # servers). Save, then re-merge the existing per-sub caches so it applies
    # immediately (no re-fetch). off/none/- clears it. The merge ignores a filter
    # that matches 0 servers (_apply_server_filter), so a typo can't empty the
    # pool. Stored via --arg (jq-safe); reject quotes/backslash/backtick/$ and cap
    # length defensively since this key is CGI-reachable.
    if [ "$key" = "server_filter" ]; then
        case "$value" in off|none|-) value="" ;; esac
        case "$value" in
            *\"*|*\\*|*\`*|*\$*) _err "server_filter: must not contain \" \\ \` or \$"; return 1 ;;
        esac
        [ "${#value}" -gt 100 ] && { _err "server_filter: too long (max 100 chars)"; return 1; }
        update_config '.[$k] = $v' --arg k "$key" --arg v "$value" || { _err "set-config save failed for $key"; return 1; }
        local _nc; _nc=$(_merge_sub_pool "$ECLIPVPN_CONFIG" 2>/dev/null)
        case "$_nc" in ''|*[!0-9]*) _nc=0 ;; esac
        jq -n --arg k "$key" --arg v "$value" --argjson n "$_nc" \
            '{status:"saved", key:$k, value:$v, pool:$n}'
        return 0
    fi
    # muted_servers: comma-separated case-sensitive NAME substrings, same matcher
    # as server_filter but a very different effect — server_filter REMOVES nodes
    # from the pool, mute only hides them from the AUTOMATIC pickers
    # (auto-select / auto-eval / watchdog failover) while leaving them one click
    # away in the UI. Motivating case: the CDN-fronted "Обход" relays are billed
    # per traffic and must not be switched on unattended.
    #
    # No re-merge here (unlike server_filter): the pool is unchanged, only who
    # may pick from it. off/none/- clears the list. Same defensive char gate and
    # a length cap, since this key is CGI-reachable; stored via --arg (jq-safe).
    if [ "$key" = "muted_servers" ]; then
        case "$value" in off|none|-) value="" ;; esac
        case "$value" in
            *\"*|*\\*|*\`*|*\$*) _err "muted_servers: must not contain \" \\ \` or \$"; return 1 ;;
        esac
        [ "${#value}" -gt 400 ] && { _err "muted_servers: too long (max 400 chars)"; return 1; }
        update_config '.[$k] = $v' --arg k "$key" --arg v "$value" || { _err "set-config save failed for $key"; return 1; }
        jq -n --arg k "$key" --arg v "$value" --argjson n "$(_muted_count "$value")" \
            '{status:"saved", key:$k, value:$v, muted_count:$n}'
        return 0
    fi
    # dns_direct_servers: ordered fallback list for the direct-path resolver.
    # Every entry must be a literal IPv4 — the value lands verbatim in the
    # generated sing-box `dns.servers[].server` field, and this key is
    # CGI-reachable. off/none/- restores the built-in Yandex pair. Only a
    # restart regenerates singbox.json, so report restart_required instead of
    # bouncing the tunnel from under a set-config call.
    if [ "$key" = "dns_direct_servers" ]; then
        case "$value" in off|none|-) value="" ;; esac
        if [ -n "$value" ]; then
            [ "${#value}" -gt 200 ] && { _err "dns_direct_servers: too long (max 200 chars)"; return 1; }
            local _ip _n=0 _oif="$IFS"
            IFS=,
            for _ip in $value; do
                IFS="$_oif"
                _ip=$(printf '%s' "$_ip" | tr -d ' ')
                if [ -n "$_ip" ]; then
                    _validate_ipv4 "$_ip" || { _err "dns_direct_servers: '$_ip' is not a valid IPv4"; return 1; }
                    _n=$((_n + 1))
                fi
                IFS=,
            done
            IFS="$_oif"
            [ "$_n" -eq 0 ] && { _err "dns_direct_servers: no valid server in the list"; return 1; }
        fi
        update_config '.[$k] = $v' --arg k "$key" --arg v "$value" || { _err "set-config save failed for $key"; return 1; }
        jq -n --arg k "$key" --arg v "$value" --arg a "$(_active_dns_direct)" \
            '{status:"saved", key:$k, value:$v, active:$a, restart_required:true}'
        return 0
    fi
    # dns_overrides: "domain=ip" pairs, comma separated — pin ONE domain family
    # to ONE resolver, ahead of every other DNS rule. Generalises the global
    # Yandex hardcode (RU banks refuse foreign resolvers): the next such domain
    # becomes a config line instead of a code change. Same defensive gate as the
    # other CGI-reachable string keys.
    if [ "$key" = "dns_overrides" ]; then
        case "$value" in off|none|-) value="" ;; esac
        if [ -n "$value" ]; then
            [ "${#value}" -gt 400 ] && { _err "dns_overrides: too long (max 400 chars)"; return 1; }
            local _pair _dom _dip _cnt=0 _oif2="$IFS"
            IFS=,
            for _pair in $value; do
                IFS="$_oif2"
                _pair=$(printf '%s' "$_pair" | tr -d ' ')
                if [ -n "$_pair" ]; then
                    case "$_pair" in *=*) ;; *) _err "dns_overrides: '$_pair' must be domain=ip"; return 1 ;; esac
                    _dom=${_pair%%=*}; _dip=${_pair##*=}
                    case "$_dom" in
                        ''|*[!a-zA-Z0-9.-]*) _err "dns_overrides: '$_dom' is not a valid domain"; return 1 ;;
                    esac
                    _validate_ipv4 "$_dip" || { _err "dns_overrides: '$_dip' is not a valid IPv4"; return 1; }
                    _cnt=$((_cnt + 1))
                fi
                IFS=,
            done
            IFS="$_oif2"
            [ "$_cnt" -eq 0 ] && { _err "dns_overrides: no valid domain=ip pair"; return 1; }
        fi
        update_config '.[$k] = $v' --arg k "$key" --arg v "$value" || { _err "set-config save failed for $key"; return 1; }
        jq -n --arg k "$key" --arg v "$value" --argjson n "$(_dns_overrides_pairs | wc -l)" \
            '{status:"saved", key:$k, value:$v, overrides:$n, restart_required:true}'
        return 0
    fi
    # Boolean keys: store as JSON true/false instead of "true"/"false" string,
    # so cmd_status's `// true` defaults work and the UI gets a real bool.
    case "$key" in
        auto_start|auto_mode|tput_guard|log_debug|full_tunnel|auto_failover)
            local bv
            case "$value" in
                true|1|on|yes) bv=true ;;
                *) bv=false ;;
            esac
            update_config '.[$k] = $v' --arg k "$key" --argjson v "$bv" || { _err "set-config save failed for $key"; return 1; }
            ;;
        tput_min_kbps|wan_mtu)
            case "$value" in ''|*[!0-9]*) _err "$key must be numeric"; return 1 ;; esac
            # wan_mtu: 0 = leave the interface alone; otherwise clamp to a
            # sane range — _apply_wan_mtu would happily set MTU 100 and
            # take the whole WAN down.
            if [ "$key" = "wan_mtu" ] && [ "$value" != "0" ]; then
                if [ "$value" -lt 576 ] || [ "$value" -gt 1500 ]; then
                    _err "wan_mtu must be 0 (off) or 576-1500"; return 1
                fi
            fi
            update_config '.[$k] = $v' --arg k "$key" --argjson v "$value" || { _err "set-config save failed for $key"; return 1; }
            ;;
        *)
            update_config '.[$k] = $v' --arg k "$key" --arg v "$value" || { _err "set-config save failed for $key"; return 1; }
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
                --arg on "$on_time" --arg off "$off_time" || { _err "schedule save failed"; return 1; }
            _setup_cron
            jq -n --arg on "$on_time" --arg off "$off_time" '{status:"schedule set",on:$on,off:$off}'
            ;;
        disable)
            update_config '.schedule.enabled = false' || { _err "schedule save failed"; return 1; }
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
# Does a restore blob's `.config` look like a REAL EclipVPN config, or a stub
# that would full-replace the live config into an unusable husk? A real config
# ALWAYS carries a routing `mode` (all_vpn|blocklist — set by the init default,
# never deleted by any path) plus either a `subscriptions` array or a legacy
# `subscription_url`. A `.config` missing `mode` is a truncated/test blob —
# restoring one once stubbed prod (subscriptions, mode AND auto_start all
# vanished, leaving an empty server list while the tunnel kept running;
# 2026-06-17). Pulled out of cmd_restore so the unit suite can exercise the
# accept/reject decision without cmd_restore's destructive accept path. Returns
# 0 = sane, 1 = stub/foreign.
_restore_config_sane() {
    printf '%s' "$1" | jq -e '
        .config
        | (type=="object")
          and ((.mode=="all_vpn") or (.mode=="blocklist"))
          and (((.subscriptions|type)=="array") or ((.subscription_url|type)=="string"))
    ' >/dev/null 2>&1
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
    # Reject a STUB/foreign blob before the FULL replace below commits it —
    # restoring a truncated config (no mode) once stubbed prod (see
    # _restore_config_sane). This is the only chance to catch it.
    if ! _restore_config_sane "$data"; then
        _err "restore: backup config incomplete (needs mode + subscriptions/subscription_url) — refusing to overwrite a working config with a stub"
        return 1
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
    _apply_device_rules
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
    _apply_device_rules
    echo "{\"status\":\"device route removed\",\"id\":\"$id\"}"
}

# Apply a device_rules change to BOTH layers it touches. A `direct` rule is an
# nftables tproxy-bypass (setup_network); a `vpn` rule (force a device through
# the tunnel even toward geoip-ru destinations — e.g. a Hik-Connect camera whose
# P2P node geo-resolves as RU) is a singbox source_ip_cidr→default route rule,
# regenerated only when the config is rebuilt. The old path rebuilt nft ONLY, so
# `vpn` device rules silently never took effect until a manual restart (the
# camera "not showing" bug, 2026-06-21). Rebuild nft for `direct`, then soft-
# restart so singbox.json picks up `vpn`. No-op when the tunnel is down — both
# layers are rebuilt from config on the next start anyway.
_apply_device_rules() {
    _vpn_running || return 0
    local iface; iface=$(get_config_val interface "br-lan")
    # Serialize the nft delete+rebuild against a watchdog failover; if the op-lock
    # is held, skip the in-place rebuild (it applies on the next (re)start).
    if _op_begin; then setup_network 2154 32768 "$iface"; _op_end; fi
    # Regenerate singbox.json so a `vpn` source_ip_cidr rule takes effect now.
    cmd_restart >/dev/null 2>&1
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
