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
    url=$(printf '%s' "$url" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    case "$url" in
        https://*|http://*) ;;
        *) logger -t flowvpn "Subscription: rejecting URL with scheme other than http(s)"; return 1 ;;
    esac

    # --dump-header writes response headers to a sidecar file. We use those to
    # extract subscription metadata (title, quota, expiry, provider announce)
    # and save it for the UI in /tmp/flowvpn/subscription_meta.json.
    local hdr_file="/tmp/flowvpn/sub_headers.txt"
    mkdir -p /tmp/flowvpn
    # umask 077 — both response body (vless:// URLs with UUIDs) and headers
    # (Subscription-Userinfo) are sensitive while we're writing them.
    umask 077
    local raw
    raw=$(curl -s --max-time 15 --proto '=http,https' \
        --dump-header "$hdr_file" "$url") || {
        logger -t flowvpn "Subscription: fetch failed (network/TLS error)"
        return 1
    }
    [ -z "$raw" ] && { logger -t flowvpn "Subscription: empty response from server"; return 1; }

    if echo "$raw" | base64 -d 2>/dev/null > "$out" && [ -s "$out" ]; then
        :
    elif _b64_pad "$raw" | base64 -d 2>/dev/null > "$out" && [ -s "$out" ]; then
        :
    else
        printf '%s' "$raw" > "$out"
    fi
    chmod 600 "$out" 2>/dev/null
    [ -s "$out" ] || { logger -t flowvpn "Subscription: decoded body is empty"; return 1; }

    _parse_subscription_headers "$hdr_file"
}

# Parse Profile-Title / Subscription-Userinfo / Announce / Profile-Update-Interval
# and write a single JSON to /tmp/flowvpn/subscription_meta.json that cmd_status
# surfaces and the UI shows on the Settings tab.
_parse_subscription_headers() {
    local hdr_file="$1"
    [ -f "$hdr_file" ] || return 0

    # Header names are case-insensitive — use grep -i and lowercase the value extraction.
    local title userinfo announce update_interval
    title=$(grep -i '^profile-title:' "$hdr_file" | head -1 | sed 's/^[Pp]rofile-[Tt]itle:[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')
    userinfo=$(grep -i '^subscription-userinfo:' "$hdr_file" | head -1 | sed 's/^[Ss]ubscription-[Uu]serinfo:[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')
    announce=$(grep -i '^announce:' "$hdr_file" | head -1 | sed 's/^[Aa]nnounce:[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')
    update_interval=$(grep -i '^profile-update-interval:' "$hdr_file" | head -1 | sed 's/^[Pp]rofile-[Uu]pdate-[Ii]nterval:[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')

    # Title may be base64-prefixed in some panels.
    case "$title" in
        base64:*) title=$(printf '%s' "${title#base64:}" | base64 -d 2>/dev/null) ;;
    esac

    # Announce can be plain or "base64:..." — providers like EclipVPN use the latter.
    local announce_text=""
    if [ -n "$announce" ]; then
        case "$announce" in
            base64:*) announce_text=$(printf '%s' "${announce#base64:}" | base64 -d 2>/dev/null) ;;
            *)        announce_text="$announce" ;;
        esac
    fi

    # Userinfo: "upload=N; download=N; total=N; expire=ts"
    local upload=0 download=0 total=0 expire=0
    if [ -n "$userinfo" ]; then
        upload=$(printf '%s' "$userinfo"   | grep -oE 'upload=[0-9]+'   | cut -d= -f2)
        download=$(printf '%s' "$userinfo" | grep -oE 'download=[0-9]+' | cut -d= -f2)
        total=$(printf '%s' "$userinfo"    | grep -oE 'total=[0-9]+'    | cut -d= -f2)
        expire=$(printf '%s' "$userinfo"   | grep -oE 'expire=[0-9]+'   | cut -d= -f2)
        [ -z "$upload" ]   && upload=0
        [ -z "$download" ] && download=0
        [ -z "$total" ]    && total=0
        [ -z "$expire" ]   && expire=0
    fi

    [ -z "$update_interval" ] || ! [ "$update_interval" -gt 0 ] 2>/dev/null && update_interval=0

    ( umask 077; jq -n \
        --arg title "$title" \
        --arg announce "$announce_text" \
        --argjson upload "$upload" \
        --argjson download "$download" \
        --argjson total "$total" \
        --argjson expire "$expire" \
        --argjson update_interval "$update_interval" \
        --argjson fetched_at "$(date +%s)" \
        '{
            title: (if $title == "" then null else $title end),
            announce: (if $announce == "" then null else $announce end),
            upload: $upload, download: $download, total: $total, expire: $expire,
            update_interval_hours: $update_interval,
            fetched_at: $fetched_at
        }' > /tmp/flowvpn/subscription_meta.json )
    rm -f "$hdr_file"
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
    # umask before writing — servers.json holds VLESS UUIDs and Reality keys
    # for every server in the subscription. Treat as a credential file.
    ( umask 077; echo "$servers" | jq '.' > "$output" )
    chmod 600 "$output" 2>/dev/null

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
