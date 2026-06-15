#!/bin/ash
# EclipVPN — xray SOCKS proxy (connects to VPN via XHTTP)

# Build an xray streamSettings object for the non-xhttp transports used by
# VMess/Trojan (tcp/ws/grpc) plus optional TLS. VLESS keeps its own inline xhttp
# builder below so its output stays byte-identical to the pre-multi-protocol era.
# Args: transport path mode security sni fp extra
_xray_stream() {
    local transport="$1" path="$2" mode="$3" security="$4" sni="$5" fp="$6" extra="$7"
    local net="$transport"
    [ -z "$net" ] && net="tcp"
    local stream
    case "$net" in
        xhttp)
            local xhttp_obj
            xhttp_obj=$(jq -n --arg path "$path" --arg mode "$mode" '{path:$path, mode:$mode}')
            if [ -n "$extra" ] && [ "$extra" != "" ]; then
                xhttp_obj=$(echo "$xhttp_obj" "$extra" | jq -s '.[0] * .[1]')
            fi
            stream=$(jq -n --argjson xhttp "$xhttp_obj" '{network:"xhttp", xhttpSettings:$xhttp, sockopt:{mark:32768}}')
            ;;
        ws)
            stream=$(jq -n --arg path "$path" --arg host "$sni" \
                'if $host == "" then {network:"ws", wsSettings:{path:$path}, sockopt:{mark:32768}}
                 else {network:"ws", wsSettings:{path:$path, headers:{Host:$host}}, sockopt:{mark:32768}} end')
            ;;
        grpc)
            stream=$(jq -n --arg sn "$path" '{network:"grpc", grpcSettings:{serviceName:$sn}, sockopt:{mark:32768}}')
            ;;
        *)
            stream=$(jq -n '{network:"tcp", sockopt:{mark:32768}}')
            ;;
    esac
    # TLS only (Reality is VLESS-only and handled in the vless branch).
    case "$security" in
        tls)
            stream=$(echo "$stream" | jq --arg sni "$sni" --arg fp "$fp" \
                '. + {security:"tls", tlsSettings:{serverName:$sni, fingerprint:$fp}}')
            ;;
    esac
    printf '%s' "$stream"
}

generate_xray_config() {
    local servers_file="$1" server_idx="$2" config_file="$3"

    local server
    # --argjson, not "$server_idx" interpolated into the jq program text: a
    # corrupt non-numeric selected_server would otherwise be a jq syntax error
    # (server="") that slips past the "null" check below into a garbage config.
    server=$(jq --argjson i "$server_idx" '.[$i]' "$servers_file" 2>/dev/null)
    [ "$server" = "null" ] || [ -z "$server" ] && return 1

    local protocol host port_s
    protocol=$(echo "$server" | jq -r '.protocol // "vless"')
    host=$(echo "$server" | jq -r '.host')
    port_s=$(echo "$server" | jq -r '.port')

    # The proxy outbound, built per-protocol. The rest of the config (SOCKS
    # inbound, direct outbound, routing) is shared and protocol-agnostic.
    local proxy
    case "$protocol" in
        vless)
            # === VLESS path — kept byte-identical to the original generator so
            # an existing servers.json regenerates the same xray.json (the
            # cmd_restart unchanged-config fast path depends on this). ===
            local uuid transport path mode security sni fp pbk sid extra flow
            uuid=$(echo "$server" | jq -r '.uuid')
            transport=$(echo "$server" | jq -r '.transport')
            path=$(echo "$server" | jq -r '.path')
            mode=$(echo "$server" | jq -r '.mode // "auto"')
            security=$(echo "$server" | jq -r '.security')
            sni=$(echo "$server" | jq -r '.sni')
            fp=$(echo "$server" | jq -r '.fp // "chrome"')
            pbk=$(echo "$server" | jq -r '.pbk')
            sid=$(echo "$server" | jq -r '.sid')
            extra=$(echo "$server" | jq -r '.extra // ""')
            flow=$(echo "$server" | jq -r '.flow // ""')

            local xhttp_obj
            xhttp_obj=$(jq -n --arg path "$path" --arg mode "$mode" '{path:$path, mode:$mode}')
            if [ -n "$extra" ] && [ "$extra" != "" ]; then
                xhttp_obj=$(echo "$xhttp_obj" "$extra" | jq -s '.[0] * .[1]')
            fi
            local stream
            stream=$(jq -n --argjson xhttp "$xhttp_obj" '{network:"xhttp", xhttpSettings:$xhttp, sockopt:{mark:32768}}')
            case "$security" in
                reality)
                    stream=$(echo "$stream" | jq \
                        --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" \
                        '. + {security:"reality", realitySettings:{serverName:$sni, fingerprint:$fp, publicKey:$pbk, shortId:$sid}}')
                    ;;
                tls)
                    stream=$(echo "$stream" | jq --arg sni "$sni" --arg fp "$fp" \
                        '. + {security:"tls", tlsSettings:{serverName:$sni, fingerprint:$fp}}')
                    ;;
            esac
            local user_obj
            user_obj=$(jq -n --arg id "$uuid" '{id:$id, encryption:"none"}')
            [ -n "$flow" ] && [ "$flow" != "" ] && user_obj=$(echo "$user_obj" | jq --arg f "$flow" '. + {flow:$f}')
            proxy=$(jq -n --arg host "$host" --argjson port_s "$port_s" --argjson user "$user_obj" --argjson stream "$stream" \
                '{tag:"proxy", protocol:"vless", settings:{vnext:[{address:$host, port:$port_s, users:[$user]}]}, streamSettings:$stream}')
            ;;
        vmess)
            local uuid alterId scy transport path mode security sni fp extra stream
            uuid=$(echo "$server" | jq -r '.uuid')
            alterId=$(echo "$server" | jq -r '.alterId // 0')
            case "$alterId" in ''|*[!0-9]*) alterId=0 ;; esac
            scy=$(echo "$server" | jq -r '.scy // "auto"')
            transport=$(echo "$server" | jq -r '.transport // ""')
            path=$(echo "$server" | jq -r '.path // ""')
            mode=$(echo "$server" | jq -r '.mode // "auto"')
            security=$(echo "$server" | jq -r '.security // ""')
            sni=$(echo "$server" | jq -r '.sni // ""')
            fp=$(echo "$server" | jq -r '.fp // "chrome"')
            extra=$(echo "$server" | jq -r '.extra // ""')
            stream=$(_xray_stream "$transport" "$path" "$mode" "$security" "$sni" "$fp" "$extra")
            proxy=$(jq -n --arg host "$host" --argjson port_s "$port_s" --arg id "$uuid" \
                --argjson aid "$alterId" --arg scy "$scy" --argjson stream "$stream" \
                '{tag:"proxy", protocol:"vmess", settings:{vnext:[{address:$host, port:$port_s, users:[{id:$id, alterId:$aid, security:$scy}]}]}, streamSettings:$stream}')
            ;;
        trojan)
            local password transport path mode security sni fp extra stream
            password=$(echo "$server" | jq -r '.password')
            transport=$(echo "$server" | jq -r '.transport // ""')
            path=$(echo "$server" | jq -r '.path // ""')
            mode=$(echo "$server" | jq -r '.mode // "auto"')
            security=$(echo "$server" | jq -r '.security // "tls"')
            sni=$(echo "$server" | jq -r '.sni // ""')
            fp=$(echo "$server" | jq -r '.fp // "chrome"')
            extra=$(echo "$server" | jq -r '.extra // ""')
            stream=$(_xray_stream "$transport" "$path" "$mode" "$security" "$sni" "$fp" "$extra")
            proxy=$(jq -n --arg host "$host" --argjson port_s "$port_s" --arg pw "$password" --argjson stream "$stream" \
                '{tag:"proxy", protocol:"trojan", settings:{servers:[{address:$host, port:$port_s, password:$pw}]}, streamSettings:$stream}')
            ;;
        shadowsocks)
            local password method stream
            password=$(echo "$server" | jq -r '.password')
            method=$(echo "$server" | jq -r '.method')
            # Shadowsocks is raw TCP (no TLS/transport security layer in xray).
            stream=$(jq -n '{network:"tcp", sockopt:{mark:32768}}')
            proxy=$(jq -n --arg host "$host" --argjson port_s "$port_s" --arg pw "$password" --arg m "$method" --argjson stream "$stream" \
                '{tag:"proxy", protocol:"shadowsocks", settings:{servers:[{address:$host, port:$port_s, method:$m, password:$pw}]}, streamSettings:$stream}')
            ;;
        *)
            logger -t eclipvpn "ERROR: protocol '$protocol' is not supported by the xray engine"
            return 1
            ;;
    esac

    # Full config: SOCKS inbound on 1080 + the per-protocol proxy outbound.
    jq -n --argjson proxy "$proxy" \
    '{
        log: {loglevel: "warning"},
        inbounds: [{
            tag: "socks-in",
            port: 1080,
            listen: "127.0.0.1",
            protocol: "socks",
            settings: {auth: "noauth", udp: true}
        }],
        outbounds: [$proxy,
        {
            tag: "direct",
            protocol: "freedom",
            streamSettings: {sockopt: {mark: 32768}}
        }],
        routing: {
            domainStrategy: "AsIs"
        }
    }' > "$config_file" || { logger -t eclipvpn "ERROR: failed to generate xray config (jq)"; return 1; }
    # A truncated/empty config here would otherwise be reported as success and
    # start_xray would fail with a misleading "xray failed".
    [ -s "$config_file" ] || { logger -t eclipvpn "ERROR: generated xray config is empty"; return 1; }
    # xray config holds live credentials (UUID/Reality keys/passwords) — 600.
    chmod 600 "$config_file" 2>/dev/null
}

start_xray() {
    local config_file="$1"
    if [ ! -x /usr/bin/xray ]; then
        logger -t eclipvpn "ERROR: /usr/bin/xray not found or not executable"
        return 1
    fi
    # Append-mode (>>) — see singbox.sh for rationale (NUL-hole sparse files).
    /usr/bin/xray run -config "$config_file" >>/tmp/eclipvpn/xray.log 2>>/tmp/eclipvpn/xray.log &
    echo $! > /tmp/eclipvpn/xray.pid

    local tries=0
    while [ "$tries" -lt 10 ]; do
        sleep 1
        tries=$((tries + 1))
        if ! kill -0 "$(cat /tmp/eclipvpn/xray.pid)" 2>/dev/null; then
            rm -f /tmp/eclipvpn/xray.pid
            return 1
        fi
        if netstat -tlnp 2>/dev/null | grep -q ":1080 "; then
            return 0
        fi
    done
    # Process alive but socks port never bound. Don't return success — the
    # caller would then apply nftables tproxy rules pointing at an unbound
    # port, stranding LAN clients. Surface the failure instead.
    logger -t eclipvpn "ERROR: xray started but socks port :1080 never opened"
    return 1
}

stop_xray() {
    local pid=""
    [ -f /tmp/eclipvpn/xray.pid ] && pid=$(cat /tmp/eclipvpn/xray.pid)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    sleep 1
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    # Sweep orphans — any other xray running with our prod config means a
    # previous restart raced and left a zombie; if we don't reap it, the
    # next start_xray spawns a third one and they fight over port 1080.
    for orphan in $(pgrep -f 'xray run -config /tmp/eclipvpn/xray.json' 2>/dev/null); do
        [ "$orphan" = "$pid" ] && continue
        kill -9 "$orphan" 2>/dev/null
    done
    rm -f /tmp/eclipvpn/xray.pid
}

is_xray_running() {
    # Belt and suspenders: pidfile may be stale (PID got reused, or a previous
    # restart wrote the wrong PID). Fall back to a config-path scan so we
    # don't trigger a spurious "VPN was killed externally" revival when the
    # process is actually fine but the pidfile is wrong.
    if [ -f /tmp/eclipvpn/xray.pid ]; then
        local pid=$(cat /tmp/eclipvpn/xray.pid 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    pgrep -f 'xray run -config /tmp/eclipvpn/xray.json' >/dev/null 2>&1
}

test_xray() {
    # Two attempts: first short (8s) for steady-state checks, second longer (12s)
    # to absorb a cold XHTTP+Reality handshake. A single 8s probe was enough to
    # spuriously flag healthy servers right after a switch (incident 2026-04-29:
    # 🇳🇱 Нидерланды, server actually up — second start of same index succeeded
    # ~3s later). Worst case here is ~21s, only on a genuinely dead tunnel.
    local ip
    ip=$(curl -s --socks5-hostname 127.0.0.1:1080 --max-time 8 https://api.ipify.org 2>/dev/null)
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    sleep 1
    curl -s --socks5-hostname 127.0.0.1:1080 --max-time 12 https://api.ipify.org 2>/dev/null
}
