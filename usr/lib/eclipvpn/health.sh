#!/bin/ash
# EclipVPN — diagnostics & info: devices, logs, DNS, diagnose, incidents, healthcheck, system-info.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers, all
# resolved at call time, so source order among the libs does not matter.

cmd_get_devices() {
    local devices="[]"
    if [ -f /tmp/dhcp.leases ]; then
        while read -r ts mac ip name id; do
            devices=$(echo "$devices" | jq --arg ip "$ip" --arg mac "$mac" --arg name "$name" \
                '. + [{ip:$ip, mac:$mac, name:$name}]')
        done < /tmp/dhcp.leases
    fi
    echo "$devices" | jq '.'
}
cmd_get_log() {
    local lines="${1:-100}" filter="${2:-all}"
    if [ ! -f "$ECLIPVPN_TMP/singbox.log" ]; then
        echo "[]"
        return
    fi

    local grep_filter=""
    case "$filter" in
        vpn)    grep_filter="outbound/socks" ;;
        direct) grep_filter="outbound/direct" ;;
        error)  grep_filter="ERROR" ;;
        dns)    grep_filter="dns:.*exchanged" ;;
        # Everything except the per-query DNS flood (UI default). Filtered before
        # the tail -N, so DNS lines cannot crowd connections out of the window.
        conn)   grep_filter="outbound/\|ERROR" ;;
        *)      grep_filter="outbound/\|ERROR\|dns:.*exchanged" ;;
    esac

    # Background-noise pattern shared with healthcheck — keeps the "Errors"
    # filter focused on real problems instead of ISP-level direct timeouts
    # to RU services and Apple push-DNS hiccups (apps retry these silently).
    local noise_excludes=""
    [ "$filter" = "error" ] && noise_excludes='\|outbound/direct.*i/o timeout\|dns: exchange failed'

    # Get timezone offset
    local tz_str=$(cat /etc/TZ 2>/dev/null)
    local TZ_OFFSET=$(echo "$tz_str" | sed 's/[A-Za-z]*//g; s/^-//' | awk '{print int($1)}')
    [ -z "$TZ_OFFSET" ] && TZ_OFFSET=3

    # Collect from multiple sources. mktemp + EXIT trap (in subshell so the
    # trap doesn't leak to the calling shell, e.g. watchdog).
    mkdir -p "$ECLIPVPN_TMP"
    (
    local tmplog
    tmplog=$(mktemp "$ECLIPVPN_TMP/combined.XXXXXX") || { echo "[]"; exit 1; }
    trap 'rm -f "$tmplog"' EXIT INT TERM

    # Source 1: sing-box log (skip for flow-only filter)
    if [ "$filter" != "flow" ]; then
        grep "$grep_filter" "$ECLIPVPN_TMP/singbox.log" 2>/dev/null | \
            grep -v "packet connection$\|WARN\|cached\|inbound/\|1\.1\.1\.1:853\|1\.0\.0\.1:853\|8\.8\.8\.8:853\|8\.8\.4\.4:853\|127\.0\.0\.1:53\|127\.0\.0\.1:5354${noise_excludes}" | \
            sed 's/\x1b\[[0-9;]*m//g; s/\x1b\[0m//g' | \
            awk '{print "SING|"$0}' >> "$tmplog"
    fi

    # Source 2: xray log — only errors
    if [ "$filter" = "all" ] || [ "$filter" = "conn" ] || [ "$filter" = "error" ]; then
        grep -iE "error|fail|warning" "$ECLIPVPN_TMP/xray.log" 2>/dev/null | \
            grep -v "accepted\|started\|Reading config\|feature Shadowsocks" | \
            tail -50 | awk '{print "XRAY|"$0}' >> "$tmplog"
    fi

    # Source 3: syslog eclipvpn entries. The syslog ringbuffer is shared
    # router-wide and can't be truncated, so filter by the "log cleared"
    # marker that cmd_clear_log writes — events older than that timestamp
    # were dismissed by the user and shouldn't reappear in the UI.
    if [ "$filter" = "all" ] || [ "$filter" = "conn" ] || [ "$filter" = "flow" ] || [ "$filter" = "error" ]; then
        local cleared_since=0
        [ -f "$ECLIPVPN_TMP/log_cleared_ts" ] && cleared_since=$(cat "$ECLIPVPN_TMP/log_cleared_ts" 2>/dev/null)
        # logread on this busybox formats lines like
        #   "Thu Apr 30 00:18:32 2026 user.notice eclipvpn: ..."
        # No epoch prefix and the time is in *local* timezone, but
        # log_cleared_ts is `date +%s` (UTC epoch). Parse the textual
        # date in awk and subtract TZ_OFFSET to compare apples to apples.
        # mktime is gawk-only, so we build the epoch by hand.
        # Errors tab: only EclipVPN's own ERROR lines (flog/_err); other tabs
        # show all eclipvpn syslog entries.
        local _sysgrep='eclipvpn:'
        [ "$filter" = "error" ] && _sysgrep='eclipvpn:.*ERROR'
        logread 2>/dev/null | grep "$_sysgrep" | tail -100 | \
            awk -v ts="${cleared_since:-0}" -v tz="${TZ_OFFSET:-3}" '
                BEGIN {
                    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ")
                    for (i=1; i<=12; i++) mn[m[i]] = i
                    split("31 28 31 30 31 30 31 31 30 31 30 31", dim, " ")
                }
                {
                    if ($1 ~ /^[A-Z][a-z]{2}$/ && $2 in mn) {
                        mo = mn[$2]; day = $3+0; year = $5+0
                        split($4, hms, ":"); hh=hms[1]+0; mi=hms[2]+0; se=hms[3]+0
                        days = (year - 1970) * 365 + int((year - 1969) / 4)
                        for (i=1; i<mo; i++) days += dim[i]
                        if (mo > 2 && (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))) days += 1
                        days += day - 1
                        # local epoch → UTC epoch.
                        epoch = days * 86400 + hh*3600 + mi*60 + se - tz*3600
                        if (epoch + 0 >= ts + 0) print
                    }
                }' | awk '{print "FLOW|"$0}' >> "$tmplog"
    fi

    # Sort and parse
    sort "$tmplog" 2>/dev/null | tail -"$lines" | \
        sed 's/\x1b\[[0-9;]*m//g; s/\x1b\[0m//g' | \
        awk -v tz="${TZ_OFFSET:-3}" '{
            # Extract source prefix (SING|, XRAY|, FLOW|)
            src="sing"
            if(substr($0,1,5)=="SING|"){src="sing";$0=substr($0,6)}
            else if(substr($0,1,5)=="XRAY|"){src="xray";$0=substr($0,6)}
            else if(substr($0,1,5)=="FLOW|"){src="flow";$0=substr($0,6)}

            # Extract time
            time=""
            for(i=1;i<=NF;i++){
                if($i ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/){
                    split($(i+1),t,":")
                    h=t[1]+0+tz; if(h>=24)h-=24; if(h<0)h+=24
                    time=$i" "sprintf("%02d:%02d:%02d",h,t[2]+0,t[3]+0)
                    break
                }
            }

            # FLOW entries (syslog: "Fri Apr 24 14:35:52 2026 user.notice eclipvpn: message")
            if(src=="flow"){
                msg=""
                for(i=1;i<=NF;i++){
                    if($i ~ /^eclipvpn/){
                        for(j=i+1;j<=NF;j++) msg=msg" "$j
                        break
                    }
                }
                # Extract time: field 4 = HH:MM:SS
                time=$1" "$2" "$3" "$4
                gsub(/^ +/,"",msg)
                if(msg != "") print time"|"msg"|flow"
                next
            }

            # XRAY entries
            if(src=="xray"){
                route="xray"
                dst=""
                if(/accepted/){
                    for(i=1;i<=NF;i++){
                        if($i=="accepted"){dst=$(i+1); break}
                    }
                } else if(/error|fail|timeout/){
                    route="error"
                    idx=0
                    for(i=1;i<=length($0);i++){if(substr($0,i,2)=="] ")idx=i+2}
                    if(idx>0)dst=substr($0,idx)
                    if(length(dst)>100)dst=substr(dst,1,100)"..."
                }
                if(dst != "") print time"|"dst"|"route
                next
            }

            # SING entries
            route=""
            if(/outbound\/socks/) route="vpn"
            else if(/outbound\/direct/) route="direct"
            else if(/ERROR/) route="error"
            else if(/dns:.*exchanged/) route="dns"

            dst=""
            if(route=="error"){
                idx=0
                for(i=1;i<=length($0);i++){if(substr($0,i,2)=="] ")idx=i+2}
                if(idx>0)dst=substr($0,idx)
                if(length(dst)>100)dst=substr(dst,1,100)"..."
            } else if(route=="dns"){
                for(i=1;i<=NF;i++){
                    if($i=="exchanged"){
                        if($(i+1)=="A"||$(i+1)=="AAAA") dst=$(i+2)" → "$(i+6)
                        else if($(i+1)=="CNAME") dst=$(i+2)" → "$(i+6)
                        else dst=$(i+1)" "$(i+2)
                        break
                    }
                }
            } else {
                for(i=1;i<=NF;i++){
                    if($i=="to"&&$(i+1)!~/^127\.|^:$|^0\.0/){dst=$(i+1);break}
                }
            }
            gsub(/\.$/,"",dst)

            if(route!=""&&(dst!=""||route=="error")) print time"|"dst"|"route
        }' | \
        jq -R -s 'split("\n") | map(select(length > 0)) | map(split("|") | {time: .[0], dst: .[1], route: .[2]})'

    rm -f "$tmplog"
    )
}
cmd_get_dns() {
    local mode=$(get_config_val mode "all_vpn")
    local dnsmasq_server=""
    dnsmasq_server=$(uci get dhcp.@dnsmasq[0].server 2>/dev/null)
    jq -n --arg mode "$mode" --arg dnsmasq "$dnsmasq_server" \
        '{mode:$mode, dnsmasq_server:$dnsmasq, proxy_dns:"tls://1.1.1.1", direct_dns:"udp://77.88.8.8",
          dot_blocked:true, quic_blocked:($mode != "all_vpn")}'
}
cmd_diagnose() {
    # Tab-separated rows (name<TAB>status<TAB>detail) → single jq at end.
    # Three network probes run in parallel (saves ~10-15s on aarch64).
    local diag_dir="$ECLIPVPN_TMP/diag.$$"
    mkdir -p "$diag_dir"
    local rows="$diag_dir/rows"
    : > "$rows"
    trap "rm -rf '$diag_dir'" EXIT INT TERM

    _add() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$rows"; }

    # Kick off network probes in parallel — they dominate total runtime.
    # _vpn_running, not is_xray_running: on a hysteria2 server sing-box owns
    # SOCKS:1080 (xray isn't running) and these probes still measure the tunnel.
    if _vpn_running; then
        local _sp; _sp=$(_active_socks_port)
        ( curl -s --socks5-hostname "127.0.0.1:$_sp" --max-time 5 https://ifconfig.me 2>/dev/null > "$diag_dir/vpn_ip" ) &
        ( curl -s --socks5-hostname "127.0.0.1:$_sp" --max-time 8 -o /dev/null -w "%{http_code}" https://youtube.com 2>/dev/null > "$diag_dir/yt_code" ) &
    fi
    ( curl -s --max-time 5 -o /dev/null -w "%{http_code}" https://yandex.ru 2>/dev/null > "$diag_dir/ya_code" ) &

    # Local checks while probes are in flight.

    # 1. proxy engine — xray, or sing-box-native for hysteria2 (no xray then).
    if [ "$(_selected_engine)" = "singbox" ]; then
        if is_singbox_running; then
            _add "движок" "ok" "Hysteria2 (нативный sing-box outbound, порт 1080)"
        else
            _add "движок" "error" "Не запущен"
        fi
    elif is_xray_running; then
        _add "xray-core" "ok" "PID $(cat /tmp/eclipvpn/xray.pid 2>/dev/null), порт 1080"
    else
        _add "xray-core" "error" "Не запущен"
    fi

    # 2. sing-box
    if is_singbox_running; then
        _add "sing-box" "ok" "PID $(cat /tmp/eclipvpn/singbox.pid 2>/dev/null), порт 2154"
    else
        _add "sing-box" "error" "Не запущен"
    fi

    # 3. nftables
    if nft list table ip eclipvpn >/dev/null 2>&1; then
        local rule_count=$(nft list table ip eclipvpn 2>/dev/null | grep -c "tproxy\|return\|reject")
        _add "nftables" "ok" "Таблица eclipvpn: $rule_count правил"
    else
        _add "nftables" "error" "Таблица eclipvpn не найдена"
    fi

    # 4. ip rule for tproxy
    if ip rule list | grep -q "fwmark 0x1"; then
        _add "ip-rule" "ok" "fwmark 0x1 → table 100"
    else
        _add "ip-rule" "error" "Правило fwmark не найдено"
    fi

    # 5. dnsmasq → sing-box
    local dns_srv=$(uci get dhcp.@dnsmasq[0].server 2>/dev/null)
    if echo "$dns_srv" | grep -q "5354"; then
        _add "dns-redirect" "ok" "dnsmasq → sing-box ($dns_srv)"
    else
        _add "dns-redirect" "warn" "dnsmasq не перенаправлен: $dns_srv"
    fi

    # 6. DNS resolution
    local dns_test=$(nslookup youtube.com 127.0.0.1 2>&1 | grep -c "Address.*[0-9]")
    if [ "$dns_test" -gt 1 ]; then
        _add "dns-resolve" "ok" "youtube.com резолвится"
    else
        _add "dns-resolve" "error" "youtube.com не резолвится"
    fi

    # Wait for the parallel probes before consuming their results.
    wait
    local vpn_ip="" yt_code="" ya_code=""
    [ -f "$diag_dir/vpn_ip" ]  && vpn_ip=$(cat "$diag_dir/vpn_ip" 2>/dev/null)
    [ -f "$diag_dir/yt_code" ] && yt_code=$(cat "$diag_dir/yt_code" 2>/dev/null)
    [ -f "$diag_dir/ya_code" ] && ya_code=$(cat "$diag_dir/ya_code" 2>/dev/null)

    # 7. VPN connection
    if ! _vpn_running; then
        _add "vpn-connection" "error" "VPN не запущен"
    elif [ -n "$vpn_ip" ]; then
        _add "vpn-connection" "ok" "VPN IP: $vpn_ip"
    else
        _add "vpn-connection" "error" "Нет ответа через VPN"
    fi

    # 8. Blocked site through VPN
    if ! _vpn_running; then
        _add "test-blocked" "error" "VPN не запущен"
    elif [ "$yt_code" = "301" ] || [ "$yt_code" = "200" ]; then
        _add "test-blocked" "ok" "youtube.com: HTTP $yt_code через VPN"
    else
        _add "test-blocked" "error" "youtube.com: HTTP $yt_code"
    fi

    # 9. RU site direct
    if [ "$ya_code" = "302" ] || [ "$ya_code" = "200" ]; then
        _add "test-direct" "ok" "yandex.ru: HTTP $ya_code напрямую"
    else
        _add "test-direct" "warn" "yandex.ru: HTTP $ya_code"
    fi

    # 10. sing-box log errors — read tail by BYTES, not lines.
    # `tail -n N` walks the file from the start on busybox, so a 45MB log
    # blocks for ~100s and overruns uhttpd's 30s network_timeout.
    # `tail -c N` seeks from the end and is O(1).
    local err_count=0 last_err=""
    if [ -f "$ECLIPVPN_TMP/singbox.log" ]; then
        local err_lines=$(tail -c 262144 "$ECLIPVPN_TMP/singbox.log" 2>/dev/null | tr -d '\0' | grep "ERROR")
        if [ -n "$err_lines" ]; then
            err_count=$(printf '%s\n' "$err_lines" | wc -l)
            last_err=$(printf '%s\n' "$err_lines" | tail -1 | sed 's/.*\] //')
        fi
    fi
    if [ "$err_count" -eq 0 ]; then
        _add "log-errors" "ok" "Ошибок нет (последние 256KB)"
    else
        _add "log-errors" "warn" "$err_count ошибок. Последняя: $last_err"
    fi

    # 11. Log size — bytes, not line count.
    local log_bytes=0 log_mb=0
    if [ -f "$ECLIPVPN_TMP/singbox.log" ]; then
        log_bytes=$(wc -c < "$ECLIPVPN_TMP/singbox.log" 2>/dev/null)
        log_mb=$((log_bytes / 1048576))
    fi
    if [ "$log_mb" -ge 10 ]; then
        _add "log-size" "warn" "${log_mb}MB — лог большой, рекомендуется очистить"
    else
        _add "log-size" "ok" "${log_mb}MB"
    fi

    # 12. Disk space
    local free_mb=$(df /overlay 2>/dev/null | tail -1 | awk '{print int($4/1024)}')
    if [ "$free_mb" -lt 5 ]; then
        _add "disk" "error" "Мало места: ${free_mb}MB свободно"
    else
        _add "disk" "ok" "${free_mb}MB свободно на /overlay"
    fi

    # Convert TSV → JSON in a single jq invocation.
    jq -R -s '
        split("\n") | map(select(length > 0)) | map(split("\t")) |
        map({name:.[0], status:.[1], detail:.[2]})
    ' < "$rows"
}
cmd_get_incidents() {
    # Self-heal after a reboot wiped /tmp: the journal lives in /etc too.
    _restore_state
    local f="$ECLIPVPN_TMP/incidents.json"
    if [ ! -f "$f" ]; then echo '{"incidents":[],"stats":[]}'; return; fi
    local now=$(date +%s)
    local h24=$((now - 86400))
    local h7d=$((now - 604800))
    # Folded: one entry per outage. Per-server counters count what was the
    # SERVER's fault — not provider outages, and not a switch TO that server.
    _incidents_fold < "$f" | jq --argjson h24 "$h24" --argjson h7d "$h7d" '
      . as $all |
      ($all | sort_by(-.ts) | .[0:200]) as $incidents |
      ($all
        | map(select(.host != null and .host != ""))
        | map(select(.type as $t | ["outage","switch_failed","slow_redial","slow_noalt","slow_noswitch"] | index($t)))
        | group_by(.host)
        | map({
            host:      .[0].host,
            server:    (max_by(.ts).server),
            count_24h: (map(select(.ts >= $h24)) | length),
            count_7d:  (map(select(.ts >= $h7d)) | length),
            last_ts:   (max_by(.ts).ts),
            last_type: (max_by(.ts).type)
          })
        | map(select(.count_7d > 0))
        | sort_by(-.count_24h, -.count_7d)
      ) as $stats |
      {incidents: $incidents, stats: $stats}
    ' 2>/dev/null || echo '{"incidents":[],"stats":[]}'
}
cmd_clear_incidents() {
    echo '[]' > "$ECLIPVPN_TMP/incidents.json"
    _mirror_state incidents.json   # or a reboot brings the cleared history back
    echo '{"status":"cleared"}'
}
cmd_system_info() {
    local fw_ver="" xray_ver="" sb_ver=""
    [ -f /etc/openwrt_release ] && fw_ver=$(awk -F"'" '/DISTRIB_DESCRIPTION/{print $2}' /etc/openwrt_release)
    xray_ver=$(/usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
    sb_ver=$(/usr/bin/sing-box version 2>/dev/null | head -1 | awk '{print $3}')
    # Hysteria2 needs a sing-box compiled with the QUIC tag — surface it so the
    # UI/diagnostics can flag hysteria2 servers as unusable on a stripped build.
    local sb_quic="false"
    /usr/bin/sing-box version 2>/dev/null | grep -q 'with_quic' && sb_quic="true"
    local sys_uptime=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    local mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    local mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    local load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    local flash_info=$(df -Pk /overlay 2>/dev/null | awk 'NR==2{print $2","$3","$4}')
    local flash_total=$(echo "$flash_info" | cut -d, -f1)
    local flash_used=$(echo "$flash_info" | cut -d, -f2)
    local flash_avail=$(echo "$flash_info" | cut -d, -f3)
    local cpu_model=$(awk -F: '/model name|Hardware/{print $2;exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ //')
    local arch=$(uname -m)
    local build_id=$(_build_id)
    jq -n \
        --arg eclipvpn "$ECLIPVPN_VERSION" \
        --arg build "$build_id" \
        --arg xray "$xray_ver" \
        --arg singbox "$sb_ver" \
        --argjson singbox_quic "$sb_quic" \
        --arg openwrt "$fw_ver" \
        --arg arch "$arch" \
        --arg cpu "$cpu_model" \
        --arg load "$load" \
        --argjson sys_uptime "${sys_uptime:-0}" \
        --argjson mem_total_kb "${mem_total:-0}" \
        --argjson mem_avail_kb "${mem_avail:-0}" \
        --argjson flash_total_kb "${flash_total:-0}" \
        --argjson flash_used_kb "${flash_used:-0}" \
        --argjson flash_avail_kb "${flash_avail:-0}" \
        '{eclipvpn:$eclipvpn, xray:$xray, singbox:$singbox, openwrt:$openwrt,
          arch:$arch, cpu:$cpu, load:$load, sys_uptime:$sys_uptime,
          mem_total_kb:$mem_total_kb, mem_avail_kb:$mem_avail_kb,
          flash_total_kb:$flash_total_kb, flash_used_kb:$flash_used_kb,
          flash_avail_kb:$flash_avail_kb, singbox_quic:$singbox_quic, build:$build}'
}
cmd_healthcheck() {
    local results="[]"
    _hc() {
        local name="$1" status="$2" detail="$3"
        results=$(echo "$results" | jq --arg n "$name" --arg s "$status" --arg d "$detail" \
            '. + [{name:$n, status:$s, detail:$d}]')
    }

    # 1. Processes — engine-aware: hysteria2 has no xray (sing-box dials it).
    if [ "$(_selected_engine)" = "singbox" ]; then
        is_singbox_running && _hc "Hysteria2" "ok" "Нативный sing-box outbound, SOCKS :1080" \
            || _hc "Hysteria2" "error" "Не запущен"
    else
        is_xray_running && _hc "xray" "ok" "PID $(cat /tmp/eclipvpn/xray.pid)" \
            || _hc "xray" "error" "Не запущен"
    fi
    is_singbox_running && _hc "sing-box" "ok" "PID $(cat /tmp/eclipvpn/singbox.pid)" \
        || _hc "sing-box" "error" "Не запущен"

    # 2. Ports — the live tunnel's SOCKS is on the ACTIVE port (rotates 1080<->1081).
    local _sp; _sp=$(_active_socks_port)
    netstat -tlnp 2>/dev/null | grep -q ":$_sp " && _hc "SOCKS :$_sp" "ok" "движок слушает" \
        || _hc "SOCKS :$_sp" "error" "Порт не открыт"
    netstat -tlnp 2>/dev/null | grep -q ":2154 " && _hc "tproxy :2154" "ok" "sing-box слушает" \
        || _hc "tproxy :2154" "error" "Порт не открыт"
    netstat -ulnp 2>/dev/null | grep -q ":5354 " && _hc "DNS :5354" "ok" "sing-box DNS слушает" \
        || _hc "DNS :5354" "error" "Порт не открыт"

    # 3. nftables
    if nft list table ip eclipvpn >/dev/null 2>&1; then
        local rc=$(nft list table ip eclipvpn 2>/dev/null | grep -c "return\|tproxy\|reject")
        _hc "nftables" "ok" "$rc правил в таблице eclipvpn"
    else
        _hc "nftables" "error" "Таблица eclipvpn не найдена"
    fi

    # 4. IP rule
    ip rule list | grep -q "fwmark 0x1" && _hc "ip rule" "ok" "fwmark 0x1 → table 100" \
        || _hc "ip rule" "error" "Правило отсутствует"

    # 5. DNS
    local dns_srv=$(uci get dhcp.@dnsmasq[0].server 2>/dev/null)
    echo "$dns_srv" | grep -q "5354" && _hc "DNS redirect" "ok" "dnsmasq → $dns_srv" \
        || _hc "DNS redirect" "warn" "dnsmasq: $dns_srv"
    nslookup youtube.com 127.0.0.1 >/dev/null 2>&1 && _hc "DNS youtube.com" "ok" "Резолвится" \
        || _hc "DNS youtube.com" "error" "Не резолвится"

    # 6. VPN connection
    if _vpn_running; then
        # -4 forces IPv4 — sing-box's strategy is ipv4_only but ifconfig.me
        # serves IPv6 too via Happy Eyeballs, which produced confusing
        # AAAA records in the "VPN туннель" check.
        local vpn_ip=$(curl -4 -s --socks5-hostname "127.0.0.1:$_sp" --max-time 8 https://ifconfig.me 2>/dev/null)
        local home_ip=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null)
        [ -n "$vpn_ip" ] && _hc "VPN туннель" "ok" "VPN IP: $vpn_ip" \
            || _hc "VPN туннель" "error" "Нет ответа"
        [ -n "$home_ip" ] && [ "$vpn_ip" != "$home_ip" ] && _hc "IP проверка" "ok" "VPN ≠ Home ($home_ip)" \
            || _hc "IP проверка" "warn" "VPN=$vpn_ip Home=$home_ip"
    fi

    # 7. Blocked sites
    for site in youtube.com instagram.com x.com; do
        local code=$(curl -s --socks5-hostname "127.0.0.1:$_sp" --max-time 8 -o /dev/null -w "%{http_code}" https://$site 2>/dev/null)
        case "$code" in 200|301|302) _hc "$site" "ok" "HTTP $code через VPN" ;; *) _hc "$site" "error" "HTTP $code" ;; esac
    done

    # 8. RU sites direct
    for site in yandex.ru vk.com sber.ru 2ip.ru; do
        local code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" https://$site 2>/dev/null)
        case "$code" in 200|301|302) _hc "$site" "ok" "HTTP $code напрямую" ;; *) _hc "$site" "warn" "HTTP $code" ;; esac
    done

    # 9. Rule-sets: query live clash API (reliable after log rotation)
    local rules_json=$(curl -s --max-time 3 -H "Authorization: Bearer $(_get_clash_secret)" http://127.0.0.1:9090/rules 2>/dev/null)
    if echo "$rules_json" | grep -q "geosite-ru"; then
        _hc "geosite-ru" "ok" "Активен"
    else
        _hc "geosite-ru" "error" "Не загружен"
    fi
    if echo "$rules_json" | grep -q "geoip-ru"; then
        _hc "geoip-ru" "ok" "Активен"
    else
        _hc "geoip-ru" "error" "Не загружен"
    fi

    # IP-leak check: simulate a LAN client by going through the xray socks
    # (the same path tproxied client packets take). Cloudflare's trace
    # endpoint reports our exit IP — it must match the current VPN IP.
    # Doing this from the router directly would always see the WAN IP
    # (router itself isn't tproxied — that would cause a routing loop).
    if _vpn_running; then
        local cur_vpn_ip trace seen_ip
        cur_vpn_ip=$(cat "$ECLIPVPN_TMP/vpn_ip" 2>/dev/null)
        trace=$(curl -s --max-time 5 --socks5-hostname "127.0.0.1:$_sp" https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
        seen_ip=$(echo "$trace" | awk -F= '/^ip=/{print $2;exit}')
        if [ -z "$seen_ip" ]; then
            _hc "IP-leak" "warn" "Не удалось проверить (нет связи через VPN)"
        elif [ -z "$cur_vpn_ip" ]; then
            # vpn_ip file may be missing right after a fresh boot before
            # cmd_start has finished writing it — not a real leak, just
            # nothing to compare to yet.
            _hc "IP-leak" "warn" "Нет сохранённого VPN IP (видно $seen_ip)"
        elif [ "$seen_ip" = "$cur_vpn_ip" ]; then
            _hc "IP-leak" "ok" "Клиенты выходят через $seen_ip (VPN)"
        else
            _hc "IP-leak" "error" "Клиенты выходят через $seen_ip — VPN IP $cur_vpn_ip не совпадает"
        fi
    fi

    # 10. Errors — count only "fresh" (last hour) and only real errors.
    # Filtered out as background noise:
    #   - "outbound/direct ... i/o timeout" — Yandex/RU sites unreachable via
    #     ISP's direct path (Lovit CGNAT). Not a VPN bug, apps retry silently.
    #   - "dns: exchange failed" — Apple push-DNS hiccups (iPhone retries).
    # What still counts as a real error: xray crashes, sing-box panics,
    # outbound/socks failures (= our VPN tunnel broke), config errors.
    local _cut=$(($(date +%s) - 3600))
    # `date -d @epoch` is GNU-only; busybox needs `-D %s -d <epoch>`. Try GNU
    # first, fall back to the busybox form so the freshness cutoff is never
    # empty (empty silently disabled the whole error count on busybox).
    local cutoff_str=$(date -u -d "@$_cut" +"%Y-%m-%d %H:%M:%S" 2>/dev/null)
    [ -z "$cutoff_str" ] && cutoff_str=$(date -u -D %s -d "$_cut" +"%Y-%m-%d %H:%M:%S" 2>/dev/null)
    local sb_err=0 xr_err=0 sb_noise=0
    if [ -n "$cutoff_str" ] && [ -f /tmp/eclipvpn/singbox.log ]; then
        local sb_counts
        sb_counts=$(grep "ERROR" /tmp/eclipvpn/singbox.log 2>/dev/null | awk -v c="$cutoff_str" '
            {
                if ($2 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) next
                ts=$2" "$3
                if (ts < c) next
                line=$0
                if (line ~ /outbound\/direct.*i\/o timeout/ || line ~ /dns: exchange failed/) noise++
                else real++
            }
            END { print (real+0)" "(noise+0) }')
        sb_err="${sb_counts%% *}"
        sb_noise="${sb_counts##* }"
    fi
    if [ -n "$cutoff_str" ] && [ -f /tmp/eclipvpn/xray.log ]; then
        # Drop xray's benign Shadowsocks-deprecation warning — it matches "errors"
        # (common/errors) but is harmless nagging when an SS server is in the pool.
        xr_err=$(grep -iE "error|fail" /tmp/eclipvpn/xray.log 2>/dev/null | grep -v "feature Shadowsocks" | awk -v c="$cutoff_str" '
            { if ($1 ~ /^[0-9]{4}\/[0-9]{2}\/[0-9]{2}$/) { gsub("/","-",$1); ts=$1" "$2; if (ts >= c) cnt++ } }
            END { print cnt+0 }')
    fi
    if [ "$sb_err" -eq 0 ] && [ "$xr_err" -eq 0 ]; then
        if [ "$sb_noise" -gt 0 ]; then
            _hc "Ошибки" "ok" "Реальных ошибок нет ($sb_noise фоновых отфильтровано)"
        else
            _hc "Ошибки" "ok" "Нет свежих ошибок (за последний час)"
        fi
    else
        _hc "Ошибки" "warn" "За последний час: sing-box: $sb_err, xray: $xr_err"
    fi

    # 11. Resources
    local free_ram=$(free | grep Mem | awk '{print int($4/1024)}')
    local free_flash=$(df /overlay 2>/dev/null | tail -1 | awk '{print int($4/1024)}')
    local cpu=$(cat /proc/loadavg | awk '{print $1}')
    [ "$free_ram" -gt 50 ] && _hc "RAM" "ok" "${free_ram}MB свободно" \
        || _hc "RAM" "warn" "${free_ram}MB свободно — мало!"
    [ "$free_flash" -gt 5 ] && _hc "Flash" "ok" "${free_flash}MB свободно" \
        || _hc "Flash" "error" "${free_flash}MB — критически мало!"
    _hc "CPU" "ok" "Load: $cpu"

    # 12. Log rotation
    local log_lines=$(wc -l < /tmp/eclipvpn/singbox.log 2>/dev/null || echo 0)
    [ "$log_lines" -lt 5000 ] && _hc "Лог" "ok" "$log_lines строк" \
        || _hc "Лог" "warn" "$log_lines строк — рекомендуется очистить"

    echo "$results" | jq '.'
}

# --- net-check: classify the DIRECT uplink's internet access -----------------
# For the UI indicator:
#   full      — both anchors reachable (normal internet)
#   whitelist — only the RU anchor answers: the uplink passes whitelisted/RU
#               hosts only (SIM with "белые списки", filtered corporate WAN…) —
#               the VPN handshake to a foreign exit will fail, and so will any
#               subscription/rules fetch; the UI should say WHY instead of
#               showing a generic "не подключается".
#   none      — neither answers: WAN itself is down.
# Anchors are IPs (no DNS — when the tunnel is down, dnsmasq→sing-box DoH is
# dead too): Yandex DNS 77.88.8.8 = RU anchor (reachable on any RU uplink incl.
# CGNAT), Google DNS 8.8.8.8 = foreign anchor. ICMP first, TCP :443 fallback —
# some uplinks filter foreign ICMP but pass TCP (the init.d WAN gate learned
# that the hard way; see _eclip_net_ready). -k because we only need the
# connect, not a cert chain. Router-own traffic bypasses tproxy (mark 0x8000
# is for the daemons; plain ping/curl from the CLI exits the raw WAN), so this
# measures the UPLINK, not the tunnel — deliberately.
_net_anchor_ok() {
    ping -c 1 -W 2 "$1" >/dev/null 2>&1 && return 0
    curl -sSk --max-time 4 --connect-timeout 4 -o /dev/null "https://$1/" 2>/dev/null && return 0
    return 1
}

cmd_net_check() {
    mkdir -p "$ECLIPVPN_TMP"
    # Probe both anchors in parallel — offline worst case stays ~6s, not 12.
    local yf="$ECLIPVPN_TMP/.net_ya.$$" gf="$ECLIPVPN_TMP/.net_gg.$$"
    ( _net_anchor_ok 77.88.8.8 && touch "$yf" ) &
    local yp=$!
    ( _net_anchor_ok 8.8.8.8 && touch "$gf" ) &
    local gp=$!
    wait "$yp" "$gp" 2>/dev/null
    local ya=false gg=false verdict
    [ -f "$yf" ] && ya=true
    [ -f "$gf" ] && gg=true
    rm -f "$yf" "$gf"
    if [ "$gg" = "true" ]; then verdict="full"
    elif [ "$ya" = "true" ]; then verdict="whitelist"
    else verdict="none"; fi
    local out
    out=$(jq -n --argjson ya "$ya" --argjson gg "$gg" --arg v "$verdict" \
        '{internet:$v, yandex:$ya, google:$gg, ts:(now|floor)}')
    # Cache the last verdict so other readers (healthcheck, future status
    # embeds) can show it without re-probing.
    printf '%s\n' "$out" > "$ECLIPVPN_TMP/net_check.json" 2>/dev/null
    printf '%s\n' "$out"
}
