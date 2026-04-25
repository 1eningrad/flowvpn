#!/bin/ash
# FlowVPN — subscription & vless:// URL parser

url_decode() {
    local data="$1"
    printf '%b' "$(echo "$data" | sed 's/+/ /g; s/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')"
}

# Pad a base64 string to a multiple of 4 with '='. Some subscription
# providers strip padding, which makes busybox `base64 -d` reject the input.
_b64_pad() {
    local s="$1" n=${#1}
    local rem=$((n % 4))
    case "$rem" in
        2) echo "${s}==" ;;
        3) echo "${s}=" ;;
        *) echo "$s" ;;
    esac
}

fetch_subscription() {
    local url="$1" out="$2"
    # Trim leading/trailing whitespace — users often paste with stray spaces.
    url=$(printf '%s' "$url" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    # Whitelist schemes — prevents SSRF (file://, ftp://, gopher://) since the
    # URL comes from user config and the call runs as root on the router.
    case "$url" in
        https://*|http://*) ;;
        *) logger -t flowvpn "Subscription: rejecting URL with scheme other than http(s)"; return 1 ;;
    esac

    local raw
    raw=$(curl -s --max-time 15 --proto '=http,https' "$url") || {
        logger -t flowvpn "Subscription: fetch failed (network/TLS error)"
        return 1
    }
    [ -z "$raw" ] && { logger -t flowvpn "Subscription: empty response from server"; return 1; }

    # Try base64 decode first; if that fails, try with padding; if that fails,
    # treat the response as already-decoded plain text (some endpoints serve
    # vless:// lines directly without base64 wrapping).
    if echo "$raw" | base64 -d 2>/dev/null > "$out" && [ -s "$out" ]; then
        :
    elif _b64_pad "$raw" | base64 -d 2>/dev/null > "$out" && [ -s "$out" ]; then
        :
    else
        printf '%s' "$raw" > "$out"
    fi
    [ -s "$out" ] || { logger -t flowvpn "Subscription: decoded body is empty"; return 1; }
}

# Validate a VLESS URL and emit JSON. Returns non-zero on malformed input
# (empty host, bogus port, missing UUID). Stays silent — caller logs.
parse_vless_url() {
    local url="$1"
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

    # Reject obviously broken entries. Some providers leave placeholder
    # "0.0.0.0" / "127.0.0.1" / port=0 entries in subscriptions and these
    # blow up xray when selected.
    [ -z "$uuid" ] && return 1
    [ -z "$host" ] && return 1
    case "$host" in
        0.0.0.0|127.0.0.1|localhost) return 1 ;;
    esac
    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$port" -le 0 ] 2>/dev/null && return 1
    [ "$port" -gt 65535 ] 2>/dev/null && return 1

    local name
    name=$(url_decode "$fragment")

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
    local total=0 rejected=0 unknown=0
    # `|| [ -n "$line" ]` ensures the last line is processed even when the
    # file has no trailing newline (common for base64-decoded subscriptions).
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim CR (Windows line endings in some subscriptions)
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        case "$line" in
            vless://*)
                total=$((total + 1))
                local srv
                if srv=$(parse_vless_url "$line"); then
                    servers=$(echo "$servers" | jq --argjson s "$srv" '. + [$s]')
                else
                    rejected=$((rejected + 1))
                fi
                ;;
            *://*)
                # Other proxy schemes (vmess://, ss://, trojan://) — count
                # so we can warn the user that their subscription contains
                # types FlowVPN doesn't speak.
                unknown=$((unknown + 1))
                ;;
        esac
    done < "$file"

    local count
    count=$(echo "$servers" | jq 'length')
    echo "$servers" | jq '.' > "$output"

    if [ "$count" -eq 0 ]; then
        if [ "$total" -eq 0 ] && [ "$unknown" -eq 0 ]; then
            logger -t flowvpn "Subscription: 0 servers parsed — expected base64-encoded list of vless:// URLs (one per line)"
        elif [ "$unknown" -gt 0 ] && [ "$total" -eq 0 ]; then
            logger -t flowvpn "Subscription: 0 vless:// servers, found $unknown other-protocol entries — FlowVPN supports only VLESS"
        else
            logger -t flowvpn "Subscription: 0 valid servers ($rejected rejected as malformed)"
        fi
    else
        [ "$rejected" -gt 0 ] && logger -t flowvpn "Subscription: $rejected of $total VLESS entries rejected (empty host / bogus port)"
        [ "$unknown" -gt 0 ] && logger -t flowvpn "Subscription: skipped $unknown non-VLESS entries"
    fi

    echo "$count"
}

update_subscription() {
    local config="$1"
    local sub_url tmp_file="/tmp/flowvpn/sub_raw.txt"
    sub_url=$(jq -r '.subscription_url' "$config")
    [ -z "$sub_url" ] || [ "$sub_url" = "null" ] && return 1

    # Defense in depth — trim here too in case set-config skipped trimming.
    sub_url=$(printf '%s' "$sub_url" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    mkdir -p /tmp/flowvpn
    fetch_subscription "$sub_url" "$tmp_file" || return 1
    parse_subscription_file "$tmp_file" /tmp/flowvpn/servers.json
}
