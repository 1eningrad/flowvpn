#!/bin/ash
# FlowVPN — subscription & vless:// URL parser

url_decode() {
    local data="$1"
    printf '%b' "$(echo "$data" | sed 's/+/ /g; s/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')"
}

fetch_subscription() {
    local url="$1" out="$2"
    local raw
    raw=$(curl -s --max-time 15 "$url") || return 1
    echo "$raw" | base64 -d 2>/dev/null > "$out"
    [ -s "$out" ] || return 1
}

parse_vless_url() {
    local url="$1"
    # vless://UUID@HOST:PORT?params#NAME
    local userhost params fragment
    local stripped="${url#vless://}"

    fragment="${stripped##*#}"
    stripped="${stripped%%#*}"

    params="${stripped#*\?}"
    stripped="${stripped%%\?*}"

    local uuid="${stripped%%@*}"
    local hostport="${stripped#*@}"
    local host="${hostport%%:*}"
    local port="${hostport##*:}"

    local name
    name=$(url_decode "$fragment")

    # Parse query params
    local security="" sni="" fp="" pbk="" sid="" transport="" path="" mode="" extra="" flow=""
    local IFS='&'
    for pair in $params; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        val=$(url_decode "$val")
        case "$key" in
            security) security="$val" ;;
            sni) sni="$val" ;;
            fp) fp="$val" ;;
            pbk) pbk="$val" ;;
            sid) sid="$val" ;;
            type) transport="$val" ;;
            path) path="$val" ;;
            mode) mode="$val" ;;
            flow) flow="$val" ;;
            extra) extra="$val" ;;
            encryption) ;; # always none for vless
        esac
    done
    unset IFS

    # Output JSON using jq
    jq -n \
        --arg name "$name" \
        --arg host "$host" \
        --arg port "$port" \
        --arg uuid "$uuid" \
        --arg security "$security" \
        --arg sni "$sni" \
        --arg fp "$fp" \
        --arg pbk "$pbk" \
        --arg sid "$sid" \
        --arg transport "$transport" \
        --arg path "$path" \
        --arg mode "$mode" \
        --arg flow "$flow" \
        --arg extra "$extra" \
        '{name:$name, host:$host, port:($port|tonumber), uuid:$uuid,
          security:$security, sni:$sni, fp:$fp, pbk:$pbk, sid:$sid,
          transport:$transport, path:$path, mode:$mode, flow:$flow, extra:$extra}'
}

parse_subscription_file() {
    local file="$1" output="$2"
    local servers="[]"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            vless://*)
                local srv
                srv=$(parse_vless_url "$line") || continue
                servers=$(echo "$servers" | jq --argjson s "$srv" '. + [$s]')
                ;;
        esac
    done < "$file"
    echo "$servers" | jq '.' > "$output"
    echo "$servers" | jq 'length'
}

update_subscription() {
    local config="$1"
    local sub_url tmp_file="/tmp/flowvpn/sub_raw.txt"
    sub_url=$(jq -r '.subscription_url' "$config")
    [ -z "$sub_url" ] || [ "$sub_url" = "null" ] && return 1

    mkdir -p /tmp/flowvpn
    fetch_subscription "$sub_url" "$tmp_file" || return 1
    parse_subscription_file "$tmp_file" /tmp/flowvpn/servers.json
}
