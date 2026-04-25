#!/bin/ash
# FlowVPN — xray SOCKS proxy (connects to VPN via XHTTP)

generate_xray_config() {
    local servers_file="$1" server_idx="$2" config_file="$3"

    local server
    server=$(jq ".[$server_idx]" "$servers_file")
    [ "$server" = "null" ] && return 1

    local host port_s uuid transport path mode security sni fp pbk sid extra flow
    host=$(echo "$server" | jq -r '.host')
    port_s=$(echo "$server" | jq -r '.port')
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

    # Build xhttp settings
    local xhttp_obj
    xhttp_obj=$(jq -n --arg path "$path" --arg mode "$mode" '{path:$path, mode:$mode}')
    if [ -n "$extra" ] && [ "$extra" != "" ]; then
        xhttp_obj=$(echo "$xhttp_obj" "$extra" | jq -s '.[0] * .[1]')
    fi

    # Build stream settings
    local stream
    stream=$(jq -n --argjson xhttp "$xhttp_obj" '{network:"xhttp", xhttpSettings:$xhttp, sockopt:{mark:32768}}')

    # Add security
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

    # Build user
    local user_obj
    user_obj=$(jq -n --arg id "$uuid" '{id:$id, encryption:"none"}')
    [ -n "$flow" ] && [ "$flow" != "" ] && user_obj=$(echo "$user_obj" | jq --arg f "$flow" '. + {flow:$f}')

    # Full config: SOCKS inbound on 1080
    jq -n \
        --arg host "$host" \
        --argjson port_s "$port_s" \
        --argjson user "$user_obj" \
        --argjson stream "$stream" \
    '{
        log: {loglevel: "warning"},
        inbounds: [{
            tag: "socks-in",
            port: 1080,
            listen: "127.0.0.1",
            protocol: "socks",
            settings: {auth: "noauth", udp: true}
        }],
        outbounds: [{
            tag: "proxy",
            protocol: "vless",
            settings: {vnext: [{address: $host, port: $port_s, users: [$user]}]},
            streamSettings: $stream
        },
        {
            tag: "direct",
            protocol: "freedom",
            streamSettings: {sockopt: {mark: 32768}}
        }],
        routing: {
            domainStrategy: "AsIs"
        }
    }' > "$config_file"
}

start_xray() {
    local config_file="$1"
    if [ ! -x /usr/bin/xray ]; then
        logger -t flowvpn "ERROR: /usr/bin/xray not found or not executable"
        return 1
    fi
    /usr/bin/xray run -config "$config_file" >/tmp/flowvpn/xray.log 2>&1 &
    echo $! > /tmp/flowvpn/xray.pid

    local tries=0
    while [ "$tries" -lt 10 ]; do
        sleep 1
        tries=$((tries + 1))
        if ! kill -0 "$(cat /tmp/flowvpn/xray.pid)" 2>/dev/null; then
            rm -f /tmp/flowvpn/xray.pid
            return 1
        fi
        if netstat -tlnp 2>/dev/null | grep -q ":1080"; then
            return 0
        fi
    done
    kill -0 "$(cat /tmp/flowvpn/xray.pid)" 2>/dev/null
}

stop_xray() {
    [ -f /tmp/flowvpn/xray.pid ] || return 0
    local pid
    pid=$(cat /tmp/flowvpn/xray.pid)
    kill "$pid" 2>/dev/null
    sleep 1
    kill -9 "$pid" 2>/dev/null
    rm -f /tmp/flowvpn/xray.pid
}

is_xray_running() {
    [ -f /tmp/flowvpn/xray.pid ] && kill -0 "$(cat /tmp/flowvpn/xray.pid)" 2>/dev/null
}

test_xray() {
    curl -s --socks5-hostname 127.0.0.1:1080 --max-time 8 https://api.ipify.org 2>/dev/null
}
