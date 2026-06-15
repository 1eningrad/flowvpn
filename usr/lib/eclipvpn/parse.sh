#!/bin/ash
# EclipVPN — proxy-URL & subscription-body parsers (pure, no network/config I/O).
# Turns vless/vmess/trojan/ss/hysteria2 URLs and base64/JSON subscription bodies
# into the uniform server-object schema. Fetching, merging across providers and
# the `sub` management command live in subscriptions.sh.

url_decode() {
    local data="$1"
    printf '%b' "$(echo "$data" | sed 's/+/ /g; s/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')"
}

# Pad a base64 string to a multiple of 4 with '='. Some subscription
# providers strip padding, which makes busybox `base64 -d` reject the input.
_b64_pad() {
    # Strip whitespace (incl. embedded newlines from 76-col-wrapped bodies)
    # BEFORE measuring length — otherwise the modulo is computed over the wrong
    # count and the padding is wrong. printf %s, not echo, so a leading -n/-e
    # in the body isn't eaten as an option.
    #
    # CRITICAL: this busybox `tr` does NOT implement the POSIX [:space:] class,
    # so `tr -d '[:space:]'` deletes the LITERAL characters [ : s p a c e ] and
    # corrupts any base64 that contains them (verified 2026-06-15: it ate the
    # 'c' from a Shadowsocks userinfo, garbling the decode). Feed tr the actual
    # whitespace BYTES via printf instead. $(...) strips only trailing newlines,
    # and the string ends in a space, so all four bytes survive.
    local s ws
    ws=$(printf '\n\r\t ')
    s=$(printf '%s' "$1" | tr -d "$ws")
    local n=${#s}
    local rem=$((n % 4))
    case "$rem" in
        2) printf '%s\n' "${s}==" ;;
        3) printf '%s\n' "${s}=" ;;
        *) printf '%s\n' "$s" ;;
    esac
}

# Validate a VLESS URL and emit JSON. Returns non-zero on malformed input
# (empty host, bogus port, missing UUID). Stays silent — caller logs.
parse_vless_url() {
    local url="$1"
    local userhost params fragment
    local stripped="${url#vless://}"

    # Only treat text after a real '#' as the name fragment. Without the guard,
    # ${stripped##*#} on a URL with NO '#' returns the ENTIRE string, so a
    # nameless entry gets name = "uuid@host:port?pbk=…" — leaking the VLESS UUID
    # out of the chmod-600 boundary into status/incidents/syslog.
    case "$stripped" in
        *'#'*) fragment="${stripped##*#}" ;;
        *)     fragment="" ;;
    esac
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
            extra)
                # `extra` from a hostile subscription server is later merged
                # into the xray xhttp config via `jq '.[0] * .[1]'`. Reject
                # anything that is not a syntactically-valid JSON object —
                # malformed JSON would break xray startup, and crafted JSON
                # could inject xhttp options (custom headers, absolute URLs).
                # Require a SINGLE JSON object. `jq -e 'type=="object"'` keys
                # off the LAST output, so multi-document input like `[1] {"a":1}`
                # passes (false,true → exit 0) and later breaks the `.[0]*.[1]`
                # merge in xray.sh. `-s` slurps every document into one array;
                # length==1 rejects the multi-doc bypass.
                if printf '%s' "$val" | jq -e -s 'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1; then
                    extra="$val"
                else
                    extra="{}"
                fi
                ;;
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
        '{protocol:"vless", name:$name, host:$host, port:($port|tonumber), uuid:$uuid,
          password:"", method:"", alterId:0, scy:"",
          security:$security, sni:$sni, fp:$fp, pbk:$pbk, sid:$sid,
          transport:$transport, path:$path, mode:$mode, flow:$flow, extra:$extra,
          obfs:"", obfs_pw:"", insecure:0}'
}

# ---------------------------------------------------------------------------
# Other proxy schemes. Each parser emits the SAME uniform server object as
# parse_vless_url (a "protocol" discriminator + per-protocol credential fields,
# unused ones empty/0) so servers.json stays one shape and xray.sh can branch on
# .protocol. Reality/pbk/sid/flow stay VLESS-only.
# ---------------------------------------------------------------------------

# trojan://password@host:port?security&sni&type&path#name — same shape as vless
# with the password in the userinfo slot (no reality, no flow).
parse_trojan_url() {
    local url="$1"
    local stripped="${url#trojan://}"
    local fragment
    case "$stripped" in
        *'#'*) fragment="${stripped##*#}" ;;
        *)     fragment="" ;;
    esac
    stripped="${stripped%%#*}"
    local params="${stripped#*\?}"
    stripped="${stripped%%\?*}"
    local password="${stripped%%@*}"
    local hostport="${stripped#*@}"
    local host="${hostport%%:*}"
    local port="${hostport##*:}"

    [ -z "$password" ] && return 1
    [ -z "$host" ] && return 1
    case "$host" in 0.0.0.0|127.0.0.1|localhost) return 1 ;; esac
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    [ "$port" -le 0 ] 2>/dev/null && return 1
    [ "$port" -gt 65535 ] 2>/dev/null && return 1

    password=$(url_decode "$password")
    local name; name=$(url_decode "$fragment")
    local security="" sni="" fp="" transport="" path="" mode="" extra=""
    local IFS='&'
    for pair in $params; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        val=$(url_decode "$val")
        case "$key" in
            security) security="$val" ;;
            sni) sni="$val" ;;
            fp) fp="$val" ;;
            type) transport="$val" ;;
            path) path="$val" ;;
            mode) mode="$val" ;;
            extra)
                if printf '%s' "$val" | jq -e -s 'length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1; then
                    extra="$val"
                else
                    extra="{}"
                fi
                ;;
        esac
    done
    unset IFS
    [ -z "$security" ] && security="tls"

    jq -n \
        --arg name "$name" --arg host "$host" --arg port "$port" \
        --arg password "$password" --arg security "$security" \
        --arg sni "$sni" --arg fp "$fp" \
        --arg transport "$transport" --arg path "$path" --arg mode "$mode" --arg extra "$extra" \
        '{protocol:"trojan", name:$name, host:$host, port:($port|tonumber), uuid:"",
          password:$password, method:"", alterId:0, scy:"",
          security:$security, sni:$sni, fp:$fp, pbk:"", sid:"",
          transport:$transport, path:$path, mode:$mode, flow:"", extra:$extra,
          obfs:"", obfs_pw:"", insecure:0}'
}

# vmess://<base64 JSON> (v2rayN format). Body is base64 of a JSON object with
# keys add/port/id/aid/net/path/tls/sni/scy/fp/ps. Decode then map via jq.
parse_vmess_url() {
    local url="$1"
    local b="${url#vmess://}"
    b="${b%%#*}"
    local json
    json=$(_b64_pad "$b" | base64 -d 2>/dev/null)
    [ -z "$json" ] && json=$(_b64_pad "$(printf '%s' "$b" | tr '_-' '/+')" | base64 -d 2>/dev/null)
    printf '%s' "$json" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
    # Validate host/uuid/port before mapping; reject placeholder entries.
    printf '%s' "$json" | jq -e '
        (.add // "") as $h
        | (.id // "") as $id
        | ((.port // 443) | if type=="string" then (tonumber? // 0) else . end) as $p
        | ($h != "" and $id != "" and $p > 0 and $p <= 65535
           and $h != "0.0.0.0" and $h != "127.0.0.1")
    ' >/dev/null 2>&1 || return 1
    printf '%s' "$json" | jq '
        {protocol:"vmess",
         name:(.ps // ""),
         host:(.add // ""),
         port:((.port // 443) | if type=="string" then (tonumber? // 0) else . end),
         uuid:(.id // ""),
         password:"", method:"",
         alterId:((.aid // 0) | if type=="string" then (tonumber? // 0) else . end),
         scy:(if (.scy // "") != "" then .scy else "auto" end),
         security:(if (.tls // "") == "tls" then "tls" else "" end),
         sni:(if (.sni // "") != "" then .sni elif (.host // "") != "" then .host else (.add // "") end),
         fp:(.fp // ""),
         pbk:"", sid:"",
         transport:(.net // ""), path:(.path // ""), mode:"", flow:"",
         extra:"",
         obfs:"", obfs_pw:"", insecure:0}'
}

# ss://<base64 method:password>@host:port#name  (SIP002), or
# ss://<base64 method:password@host:port>#name  (legacy). plugin= rejected.
parse_ss_url() {
    local url="$1"
    local b="${url#ss://}"
    local fragment
    case "$b" in
        *'#'*) fragment="${b##*#}" ;;
        *)     fragment="" ;;
    esac
    b="${b%%#*}"
    case "$b" in
        *'?'*)
            local q="${b#*\?}"
            case "$q" in *plugin=*) return 1 ;; esac   # obfs / v2ray-plugin out of scope
            b="${b%%\?*}"
            ;;
    esac
    local name; name=$(url_decode "$fragment")
    local method="" password="" host="" port="" dec=""
    case "$b" in
        *@*)
            local userinfo="${b%%@*}"
            local hostport="${b#*@}"
            host="${hostport%%:*}"
            port="${hostport##*:}"
            dec=$(_b64_pad "$userinfo" | base64 -d 2>/dev/null)
            [ -z "$dec" ] && dec=$(_b64_pad "$(printf '%s' "$userinfo" | tr '_-' '/+')" | base64 -d 2>/dev/null)
            case "$dec" in
                *:*) method="${dec%%:*}"; password="${dec#*:}" ;;
                *)   case "$userinfo" in *:*) method="${userinfo%%:*}"; password="${userinfo#*:}" ;; *) return 1 ;; esac ;;
            esac
            ;;
        *)
            dec=$(_b64_pad "$b" | base64 -d 2>/dev/null)
            [ -z "$dec" ] && dec=$(_b64_pad "$(printf '%s' "$b" | tr '_-' '/+')" | base64 -d 2>/dev/null)
            case "$dec" in *@*) ;; *) return 1 ;; esac
            local cred="${dec%%@*}"
            local hostport="${dec##*@}"
            method="${cred%%:*}"
            password="${cred#*:}"
            host="${hostport%%:*}"
            port="${hostport##*:}"
            ;;
    esac

    [ -z "$method" ] && return 1
    [ -z "$password" ] && return 1
    [ -z "$host" ] && return 1
    case "$host" in 0.0.0.0|127.0.0.1|localhost) return 1 ;; esac
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    [ "$port" -le 0 ] 2>/dev/null && return 1
    [ "$port" -gt 65535 ] 2>/dev/null && return 1

    jq -n \
        --arg name "$name" --arg host "$host" --arg port "$port" \
        --arg method "$method" --arg password "$password" \
        '{protocol:"shadowsocks", name:$name, host:$host, port:($port|tonumber), uuid:"",
          password:$password, method:$method, alterId:0, scy:"",
          security:"", sni:"", fp:"", pbk:"", sid:"",
          transport:"", path:"", mode:"", flow:"", extra:"",
          obfs:"", obfs_pw:"", insecure:0}'
}

# hysteria2://auth@host:port/?obfs=salamander&obfs-password=..&sni=..&insecure=1#name
# hy2:// is an accepted alias. Hysteria2 is QUIC-only — xray can't speak it, so
# the engine layer routes it to a NATIVE sing-box outbound (see xray.sh comment
# and singbox.sh::_singbox_proxy_outbound), not the xray SOCKS path. The auth
# string lives in the userinfo slot (password). obfs (salamander only) and
# insecure are optional. Reality fields (pbk/sid/flow) stay empty — N/A here.
parse_hysteria2_url() {
    local url="$1"
    local stripped="${url#hysteria2://}"
    stripped="${stripped#hy2://}"   # collapse the hy2:// alias too
    local fragment
    case "$stripped" in
        *'#'*) fragment="${stripped##*#}" ;;
        *)     fragment="" ;;
    esac
    stripped="${stripped%%#*}"
    local params=""
    case "$stripped" in
        *'?'*) params="${stripped#*\?}"; stripped="${stripped%%\?*}" ;;
    esac
    # Require userinfo@host. Without an '@', both expansions below collapse to
    # the whole string (password = "host:port"), producing a bogus server that
    # passes the non-empty checks and then silently fails auth. Reject instead.
    case "$stripped" in *@*) ;; *) return 1 ;; esac
    local password="${stripped%%@*}"
    local hostport="${stripped#*@}"
    # Drop a trailing path/slash on the authority (hysteria2://auth@host:port/).
    hostport="${hostport%%/*}"
    local host="${hostport%%:*}"
    local port="${hostport##*:}"

    [ -z "$password" ] && return 1
    [ -z "$host" ] && return 1
    case "$host" in 0.0.0.0|127.0.0.1|localhost) return 1 ;; esac
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    [ "$port" -le 0 ] 2>/dev/null && return 1
    [ "$port" -gt 65535 ] 2>/dev/null && return 1

    password=$(url_decode "$password")
    local name; name=$(url_decode "$fragment")
    local sni="" obfs="" obfs_pw="" insecure=0
    local IFS='&'
    for pair in $params; do
        local key="${pair%%=*}"
        local val="${pair#*=}"
        val=$(url_decode "$val")
        case "$key" in
            sni|peer)      sni="$val" ;;
            obfs)          obfs="$val" ;;
            obfs-password) obfs_pw="$val" ;;
            insecure|allowInsecure)
                case "$val" in 1|true|TRUE|True) insecure=1 ;; esac ;;
        esac
    done
    unset IFS
    # sing-box only implements the "salamander" obfuscator; drop anything else
    # so a stray obfs=xplus doesn't make sing-box reject the whole outbound.
    case "$obfs" in salamander) ;; *) obfs=""; obfs_pw="" ;; esac

    jq -n \
        --arg name "$name" --arg host "$host" --arg port "$port" \
        --arg password "$password" --arg sni "$sni" \
        --arg obfs "$obfs" --arg obfs_pw "$obfs_pw" --argjson insecure "$insecure" \
        '{protocol:"hysteria2", name:$name, host:$host, port:($port|tonumber), uuid:"",
          password:$password, method:"", alterId:0, scy:"",
          security:"tls", sni:$sni, fp:"", pbk:"", sid:"",
          transport:"", path:"", mode:"", flow:"", extra:"",
          obfs:$obfs, obfs_pw:$obfs_pw, insecure:$insecure}'
}

# Scheme dispatcher — route a proxy URL to the right parser. Unknown -> 1.
parse_proxy_url() {
    local url="$1"
    case "$url" in
        vless://*)             parse_vless_url     "$url" ;;
        vmess://*)             parse_vmess_url     "$url" ;;
        trojan://*)            parse_trojan_url    "$url" ;;
        ss://*)                parse_ss_url        "$url" ;;
        hysteria2://*|hy2://*) parse_hysteria2_url "$url" ;;
        *) return 1 ;;
    esac
}

# Parse a JSON subscription body into servers.json. Accepts a bare array or a
# {"servers":[...]} wrapper; each element is either a proxy-URL string (reused
# through parse_proxy_url) or a full server object. `extra` may be a nested
# object or a JSON string — it's normalised to a string (same shape the vless://
# path produces, so xray.sh's `jq -s '.[0]*.[1]'` merge keeps working). Echoes
# the server count (0 = caller keeps the previous servers.json, fetch-then-swap).
_parse_json_subscription() {
    local file="$1" output="$2"
    local total
    total=$(jq '(if type=="array" then . elif (type=="object" and has("servers")) then .servers else [] end) | length' "$file" 2>/dev/null)
    case "$total" in ''|*[!0-9]*) total=0 ;; esac

    # Map object entries to the canonical schema and validate (host/uuid/port).
    local valid_objs
    valid_objs=$(jq -c '
        (if type=="array" then . elif (type=="object" and has("servers")) then .servers else [] end)
        | [ .[] | select(type=="object")
            | { protocol:(.protocol // "vless"),
                name:(.name//""), host:(.host//""),
                port:(((.port//443)) | if type=="string" then (tonumber? // 0) else . end),
                uuid:(.uuid//""), password:(.password//""), method:(.method//""),
                alterId:((.alterId//0) | if type=="string" then (tonumber? // 0) else . end),
                scy:(.scy//""),
                security:(.security//""), sni:(.sni//""),
                fp:(.fp//""), pbk:(.pbk//""), sid:(.sid//""),
                transport:(.transport//""), path:(.path//""), mode:(.mode//""), flow:(.flow//""),
                extra:((.extra // {}) | if type=="string" then . else tojson end),
                obfs:(.obfs//""), obfs_pw:(.obfs_pw//""),
                insecure:((.insecure//0) | if type=="boolean" then (if . then 1 else 0 end) elif type=="string" then (tonumber? // 0) else . end) } ]
        | map(select(.host!="" and (.port|type)=="number"
              and .port>0 and .port<=65535 and .host!="0.0.0.0" and .host!="127.0.0.1"
              and ( ((.protocol=="vless" or .protocol=="vmess") and .uuid!="")
                    or ((.protocol=="trojan" or .protocol=="shadowsocks" or .protocol=="hysteria2") and .password!="") ) ))
    ' "$file" 2>/dev/null)
    [ -z "$valid_objs" ] && valid_objs="[]"

    # Any proxy-URL string entries go through the scheme dispatcher.
    local vlines
    vlines=$(jq -r '
        (if type=="array" then . elif (type=="object" and has("servers")) then .servers else [] end)
        | [ .[] | select(type=="string") | select(test("^(vless|vmess|trojan|ss|hysteria2|hy2)://")) ] | .[]
    ' "$file" 2>/dev/null)

    local out="$valid_objs"
    if [ -n "$vlines" ]; then
        local oldifs="$IFS"; IFS='
'
        local vline srv
        for vline in $vlines; do
            [ -z "$vline" ] && continue
            if srv=$(parse_proxy_url "$vline"); then
                out=$(printf '%s' "$out" | jq -c --argjson s "$srv" '. + [$s]')
            fi
        done
        IFS="$oldifs"
    fi

    local count
    count=$(printf '%s' "$out" | jq 'length' 2>/dev/null)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    ( umask 077; printf '%s' "$out" | jq '.' > "$output" )
    chmod 600 "$output" 2>/dev/null

    local rej=$((total - count)); [ "$rej" -lt 0 ] && rej=0
    if [ "$count" -eq 0 ]; then
        logger -t eclipvpn "Subscription(JSON): 0 valid servers (saw $total entries — need host/uuid/port or vless:// strings)"
    elif [ "$rej" -gt 0 ]; then
        logger -t eclipvpn "Subscription(JSON): $rej of $total entries rejected (missing host/uuid / bad port)"
    fi
    echo "$count"
}

parse_subscription_file() {
    local file="$1" output="$2"
    # Same URL may return JSON instead of the classic base64 vless:// list.
    # Detect with jq directly (a base64 / vless:// body is never a valid
    # top-level JSON array or object) — do NOT sniff the first char with
    # `tr -d '[:space:]'`: busybox tr reads that as the literal set
    # [ : s p a c e ] and strips the leading '[', breaking detection.
    if jq -e 'type=="array" or type=="object"' "$file" >/dev/null 2>&1; then
        _parse_json_subscription "$file" "$output"
        return
    fi
    local servers="[]"
    local total=0 rejected=0 unknown=0
    # `|| [ -n "$line" ]` ensures the last line is processed even when the
    # file has no trailing newline (common for base64-decoded subscriptions).
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim CR (Windows line endings in some subscriptions)
        line="${line%$'\r'}"
        [ -z "$line" ] && continue
        case "$line" in
            vless://*|vmess://*|trojan://*|ss://*|hysteria2://*|hy2://*)
                total=$((total + 1))
                local srv
                if srv=$(parse_proxy_url "$line"); then
                    servers=$(echo "$servers" | jq --argjson s "$srv" '. + [$s]')
                else
                    rejected=$((rejected + 1))
                fi
                ;;
            *://*)
                # Schemes EclipVPN doesn't speak yet (tuic://, wireguard://) —
                # count so we can warn the user.
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
            logger -t eclipvpn "Subscription: 0 servers parsed — expected base64-encoded list of proxy URLs (one per line)"
        elif [ "$unknown" -gt 0 ] && [ "$total" -eq 0 ]; then
            logger -t eclipvpn "Subscription: 0 supported servers, found $unknown unsupported entries (tuic/wireguard not yet supported)"
        else
            logger -t eclipvpn "Subscription: 0 valid servers ($rejected rejected as malformed)"
        fi
    else
        [ "$rejected" -gt 0 ] && logger -t eclipvpn "Subscription: $rejected of $total entries rejected (empty host / bogus port / bad credential)"
        [ "$unknown" -gt 0 ] && logger -t eclipvpn "Subscription: skipped $unknown unsupported-protocol entries"
    fi

    echo "$count"
}

