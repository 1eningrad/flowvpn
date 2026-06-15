#!/bin/ash
# EclipVPN — subscription & vless:// URL parser

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

# Stable per-router hardware ID for the panel's device-binding / HWID limit.
# Lazily generated once and persisted to /etc/eclipvpn/hwid (chmod 600, same
# pattern as clash_secret). We mint our own UUID instead of deriving it from the
# MAC so the value isn't externally guessable and a board swap is a deliberate
# re-register. It survives reboots and any upgrade that preserves /etc. Kept out
# of `backup` on purpose — it's device-specific and must not be cloned onto
# another router by `restore`.
_get_hwid() {
    local f=/etc/eclipvpn/hwid
    if [ ! -s "$f" ]; then
        mkdir -p /etc/eclipvpn
        local id=""
        [ -r /proc/sys/kernel/random/uuid ] && id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
        [ -z "$id" ] && id=$(head -c 16 /dev/urandom 2>/dev/null | hexdump -v -e '/1 "%02x"' 2>/dev/null)
        [ -z "$id" ] && id=$(awk 'BEGIN{srand();for(i=0;i<32;i++)printf "%x",int(rand()*16)}')
        printf '%s' "$id" > "$f"
        chmod 600 "$f" 2>/dev/null
    fi
    cat "$f"
}

# Subscription fetch with HWID + device-metadata headers (Remnawave-style). The
# panel keys its per-user device limit off X-HWID and shows the rest in its
# dashboard. Panels that don't care simply ignore the extra headers. $1=url,
# $2=header-dump file. Both the initial fetch and the landing-page follow-up go
# through here so the identity is consistent.
_sub_curl() {
    local os_ver model
    os_ver=$(awk -F"'" '/DISTRIB_RELEASE/{print $2}' /etc/openwrt_release 2>/dev/null)
    [ -z "$os_ver" ] && os_ver=$(awk -F"'" '/DISTRIB_DESCRIPTION/{print $2}' /etc/openwrt_release 2>/dev/null)
    # Trim the parenthetical hardware-revision suffix OpenWrt appends, e.g.
    # "Cudy WBR3000UAX v1 (OpenWrt U-Boot layout)" -> "Cudy WBR3000UAX v1".
    model=$(cat /tmp/sysinfo/model 2>/dev/null | sed 's/ *(.*$//; s/[[:space:]]*$//')
    [ -z "$model" ] && model=$(cat /tmp/sysinfo/board_name 2>/dev/null)
    [ -z "$model" ] && model="OpenWrt Router"
    curl -fsS --max-time 15 --proto '=http,https' \
        -A "EclipVPN/${ECLIPVPN_VERSION}" \
        -H "X-HWID: $(_get_hwid)" \
        -H "X-Device-OS: OpenWrt" \
        -H "X-Ver-OS: $os_ver" \
        -H "X-Device-Model: $model" \
        --dump-header "$2" "$1"
}

fetch_subscription() {
    local url="$1" out="$2"
    url=$(printf '%s' "$url" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    case "$url" in
        https://*|http://*) ;;
        *) logger -t eclipvpn "Subscription: rejecting URL with scheme other than http(s)"; return 1 ;;
    esac

    # --dump-header writes response headers to a sidecar file. We use those to
    # extract subscription metadata (title, quota, expiry, provider announce)
    # and save it for the UI in /tmp/eclipvpn/subscription_meta.json.
    local hdr_file="/tmp/eclipvpn/sub_headers.txt"
    mkdir -p /tmp/eclipvpn
    # umask 077 — both response body (vless:// URLs with UUIDs) and headers
    # (Subscription-Userinfo) are sensitive while we're writing them. Saved and
    # restored on every exit path so the tightened mask doesn't silently leak
    # into every other file this eclipvpn invocation creates afterwards
    # (rule lists, logs, pids would all become 600/700).
    local _oumask; _oumask=$(umask)
    umask 077
    local raw
    raw=$(_sub_curl "$url" "$hdr_file") || {
        umask "$_oumask"
        logger -t eclipvpn "Subscription: fetch failed (HTTP >=400, network, or TLS error)"
        return 1
    }
    [ -z "$raw" ] && { umask "$_oumask"; logger -t eclipvpn "Subscription: empty response from server"; return 1; }

    # EclipVPN's bot hands users the user-facing landing URL
    # (<panel-host>/<token>) instead of the API endpoint
    # (<panel-host>/api/sub/<token>). The landing page embeds the
    # API path in its HTML — detect that and follow transparently so users
    # don't need to know the difference.
    case "$raw" in
        *"<!DOCTYPE html"*|*"<!doctype html"*|*"<html"*)
            local sub_path follow_url prefix
            sub_path=$(printf '%s' "$raw" | grep -oE '/api/sub/[A-Za-z0-9_-]+' | head -1)
            if [ -n "$sub_path" ]; then
                prefix=$(printf '%s' "$url" | sed -E 's#^(https?://[^/]+).*#\1#')
                follow_url="${prefix}${sub_path}"
                logger -t eclipvpn "Subscription: landing page detected, following /api/sub/<redacted>"
                raw=$(_sub_curl "$follow_url" "$hdr_file") || {
                    umask "$_oumask"
                    logger -t eclipvpn "Subscription: follow-up fetch to api endpoint failed"
                    return 1
                }
                [ -z "$raw" ] && { umask "$_oumask"; logger -t eclipvpn "Subscription: api endpoint returned empty body"; return 1; }
            fi
            ;;
    esac

    # Decode the subscription body. Panels return one of: standard base64 of
    # vless:// lines (EclipVPN, most), URL-safe base64 (-_ instead of +/), or
    # already-plaintext vless://. Accept the FIRST decode whose output actually
    # contains URL-looking lines ("://") — the grep guard prevents accepting a
    # garbage decode (e.g. running the URL-safe -_->/+ transform over STANDARD
    # base64, which silently corrupts it). Fall back to $raw as plaintext.
    # A JSON body (array / {"servers":[...]}) is a subscription too — keep it
    # verbatim and let parse_subscription_file detect+parse it. Short-circuit
    # before the base64 cascade so a JSON body can't be mangled by a stray
    # base64 decode that happens to contain "://". Detect with jq directly: a
    # base64 / vless:// body is never a valid top-level JSON array or object.
    if printf '%s' "$raw" | jq -e 'type=="array" or type=="object"' >/dev/null 2>&1; then
        printf '%s' "$raw" > "$out"
    elif printf '%s' "$raw" | base64 -d 2>/dev/null > "$out" && grep -q '://' "$out" 2>/dev/null; then
        :
    elif _b64_pad "$raw" | base64 -d 2>/dev/null > "$out" && grep -q '://' "$out" 2>/dev/null; then
        :
    elif _b64_pad "$(printf '%s' "$raw" | tr '_-' '/+')" | base64 -d 2>/dev/null > "$out" && grep -q '://' "$out" 2>/dev/null; then
        # URL-safe base64 (-_ instead of +/). _b64_pad strips whitespace and
        # re-pads — busybox base64 -d rejects the unpadded form panels often send.
        :
    else
        printf '%s' "$raw" > "$out"
    fi
    chmod 600 "$out" 2>/dev/null
    umask "$_oumask"
    [ -s "$out" ] || { logger -t eclipvpn "Subscription: decoded body is empty"; return 1; }

    _parse_subscription_headers "$hdr_file"
}

# Parse Profile-Title / Subscription-Userinfo / Announce / Profile-Update-Interval
# and write a single JSON to /tmp/eclipvpn/subscription_meta.json that cmd_status
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

    # Numerics come in as --arg strings and convert via `tonumber? // 0`, NOT
    # --argjson: a leading-zero value (upload=007) or any garbage from a 200
    # error page is invalid JSON for --argjson, which would abort jq AFTER the
    # shell already truncated the file — wiping previously-good meta to 0 bytes.
    # tonumber? swallows the bad value; temp+mv keeps the old meta on any failure.
    ( umask 077
      jq -n \
        --arg title "$title" \
        --arg announce "$announce_text" \
        --arg upload "$upload" \
        --arg download "$download" \
        --arg total "$total" \
        --arg expire "$expire" \
        --arg update_interval "$update_interval" \
        --argjson fetched_at "$(date +%s)" \
        '{
            title: (if $title == "" then null else $title end),
            announce: (if $announce == "" then null else $announce end),
            upload: ($upload|tonumber? // 0), download: ($download|tonumber? // 0),
            total: ($total|tonumber? // 0), expire: ($expire|tonumber? // 0),
            update_interval_hours: ($update_interval|tonumber? // 0),
            fetched_at: $fetched_at
        }' > /tmp/eclipvpn/subscription_meta.json.tmp \
        && mv /tmp/eclipvpn/subscription_meta.json.tmp /tmp/eclipvpn/subscription_meta.json \
        || rm -f /tmp/eclipvpn/subscription_meta.json.tmp )
    rm -f "$hdr_file"
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

# Scheme dispatcher — route a proxy URL to the right parser. Unknown -> 1.
parse_proxy_url() {
    local url="$1"
    case "$url" in
        vless://*)  parse_vless_url  "$url" ;;
        vmess://*)  parse_vmess_url  "$url" ;;
        trojan://*) parse_trojan_url "$url" ;;
        ss://*)     parse_ss_url     "$url" ;;
        *) return 1 ;;
    esac
}

# Parse a JSON subscription body into servers.json. Accepts a bare array or a
# {"servers":[...]} wrapper; each element is either a vless:// string (reused
# through parse_vless_url) or a full server object. `extra` may be a nested
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
            | { name:(.name//""), host:(.host//""),
                port:(((.port//443)) | if type=="string" then (tonumber? // 0) else . end),
                uuid:(.uuid//""), security:(.security//""), sni:(.sni//""),
                fp:(.fp//""), pbk:(.pbk//""), sid:(.sid//""),
                transport:(.transport//""), path:(.path//""), mode:(.mode//""), flow:(.flow//""),
                extra:((.extra // {}) | if type=="string" then . else tojson end) } ]
        | map(select(.host!="" and .uuid!="" and (.port|type)=="number"
              and .port>0 and .port<=65535 and .host!="0.0.0.0" and .host!="127.0.0.1"))
    ' "$file" 2>/dev/null)
    [ -z "$valid_objs" ] && valid_objs="[]"

    # Any vless:// string entries go through the existing URL parser.
    local vlines
    vlines=$(jq -r '
        (if type=="array" then . elif (type=="object" and has("servers")) then .servers else [] end)
        | [ .[] | select(type=="string") | select(test("^vless://")) ] | .[]
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
            vless://*|vmess://*|trojan://*|ss://*)
                total=$((total + 1))
                local srv
                if srv=$(parse_proxy_url "$line"); then
                    servers=$(echo "$servers" | jq --argjson s "$srv" '. + [$s]')
                else
                    rejected=$((rejected + 1))
                fi
                ;;
            *://*)
                # Schemes EclipVPN doesn't speak yet (hysteria2://, tuic://,
                # wireguard://) — count so we can warn the user.
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
            logger -t eclipvpn "Subscription: 0 supported servers, found $unknown unsupported entries (hysteria2/tuic/wireguard not yet supported)"
        else
            logger -t eclipvpn "Subscription: 0 valid servers ($rejected rejected as malformed)"
        fi
    else
        [ "$rejected" -gt 0 ] && logger -t eclipvpn "Subscription: $rejected of $total entries rejected (empty host / bogus port / bad credential)"
        [ "$unknown" -gt 0 ] && logger -t eclipvpn "Subscription: skipped $unknown unsupported-protocol entries"
    fi

    echo "$count"
}

update_subscription() {
    local config="$1"
    local sub_url tmp_file="/tmp/eclipvpn/sub_raw.txt"
    sub_url=$(jq -r '.subscription_url' "$config")
    [ -z "$sub_url" ] || [ "$sub_url" = "null" ] && return 1

    # Defense in depth — trim here too in case set-config skipped trimming.
    sub_url=$(printf '%s' "$sub_url" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    mkdir -p /tmp/eclipvpn
    fetch_subscription "$sub_url" "$tmp_file" || return 1
    # Parse into a sidecar and commit only on a non-empty result. Writing
    # straight to servers.json meant a fetch that SUCCEEDED but parsed to
    # zero servers (panel format change, garbage body that slipped past the
    # base64 guard) replaced the live server list with [] — breaking status,
    # restarts and failover until the panel recovered.
    local new_file=/tmp/eclipvpn/servers.json.new count
    count=$(parse_subscription_file "$tmp_file" "$new_file")
    if [ "$count" -gt 0 ] 2>/dev/null; then
        mv "$new_file" /tmp/eclipvpn/servers.json
    else
        rm -f "$new_file"
    fi
    echo "$count"
}
