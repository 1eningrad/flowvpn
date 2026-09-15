#!/bin/ash
# EclipVPN — subscriptions: multi-provider fetch, merge & management.
# Sourced into /usr/bin/eclipvpn; shares its globals and helpers, all resolved
# at call time, so source order among the libs does not matter.
#
# Several VPN-provider subscriptions can be configured at once
# (config.subscriptions[] = [{id,name,url,enabled},...]). update_subscription
# fetches every enabled one (each into its own fetch-then-swap cache), tags each
# server with sub_id/sub_name, and merges them into ONE flat servers.json — so
# the whole index-based engine (set-server N, auto-select, failover, probe,
# traffic, incidents) stays unchanged. `subscription_url` is kept as a mirror of
# subscriptions[0] for back-compat. Proxy-URL / body PARSING lives in parse.sh;
# this lib is fetch + merge + manage.

# --- id + one-time migration (was in usr/bin/eclipvpn) ----------------------
# Stable per-URL id (first 8 hex of md5). Same URL ⇒ same id ⇒ adding a sub
# twice is idempotent (dedup). md5sum is in busybox.
_sub_id_for_url() {
    printf '%s' "$1" | md5sum 2>/dev/null | cut -c1-8
}

# A "manual server" subscription: the entry's url IS a single proxy URI
# (vless://…), not a fetchable panel URL. It rides the whole subscriptions[]
# machinery (id, enable/disable/remove, merge, remap, UI) but is parsed locally
# by parse_proxy_url — never fetched. Scheme set = parse_proxy_url's dispatcher.
_is_proxy_uri() {
    case "$1" in
        vless://*|vmess://*|trojan://*|ss://*|hysteria2://*|hy2://*) return 0 ;;
        *) return 1 ;;
    esac
}

# (Re)build the per-sub cache for a manual-server subscription: parse the URI,
# tag sub_id/sub_name, write the cache atomically and mirror it to the
# persistent subcache (same contract as update_subscription's fetch path, so
# merge / reboot-restore treat manual and fetched subs identically). No network.
# $1=sub id, $2=proxy URI, $3=sub name. Returns 1 if the URI doesn't parse.
_manual_sub_cache() {
    local sid="$1" uri="$2" sname="$3"
    local tmp="${ECLIPVPN_TMP:-/tmp/eclipvpn}"
    local scache; scache="$(dirname "${ECLIPVPN_CONFIG:-/etc/eclipvpn/config.json}")/subcache"
    mkdir -p "$tmp" "$scache" 2>/dev/null
    local srv; srv=$(parse_proxy_url "$uri") || return 1
    [ -z "$srv" ] && return 1
    local cache="$tmp/sub.$sid.servers.json"
    ( umask 077; printf '%s' "$srv" \
        | jq -c --arg sid "$sid" --arg sname "$sname" '[ . + {sub_id:$sid, sub_name:$sname} ]' \
        > "$cache.tmp" 2>/dev/null ) && [ -s "$cache.tmp" ] || { rm -f "$cache.tmp"; return 1; }
    mv "$cache.tmp" "$cache"
    chmod 600 "$cache" 2>/dev/null
    cp "$cache" "$scache/" 2>/dev/null && chmod 600 "$scache/$(basename "$cache")" 2>/dev/null
    return 0
}

# One-time migration: synthesize config.subscriptions[] from a legacy single
# subscription_url. Idempotent — returns immediately once subscriptions[] is an
# array, so it's cheap to call at every init. Runs before the dispatch case so
# every entry point (CLI/CGI/watchdog) sees the new shape.
_migrate_subscriptions() {
    [ -f "$ECLIPVPN_CONFIG" ] || return 0
    local has; has=$(jq -r 'if (.subscriptions|type)=="array" then "y" else "n" end' "$ECLIPVPN_CONFIG" 2>/dev/null)
    [ "$has" = "y" ] && return 0
    local url; url=$(jq -r '.subscription_url // ""' "$ECLIPVPN_CONFIG" 2>/dev/null)
    if [ -n "$url" ] && [ "$url" != "null" ]; then
        update_config '.subscriptions = [{id:$id, name:"Подписка 1", url:$url, enabled:true, name_auto:true}]' \
            --arg id "$(_sub_id_for_url "$url")" --arg url "$url"
    else
        update_config '.subscriptions = []'
    fi
}

# --- fetch + per-provider metadata (was in parse.sh) ------------------------
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
    local hwid; hwid=$(_get_hwid)
    # Fetch via the shared _router_fetch primitive (the ONE place the direct→
    # tunnel fallback lives — so a vercel-hosted panel blocked from RU still
    # loads through the live SOCKS exit). It's file-based, so stage the body in a
    # temp and emit it; the device-identity headers + response-header dump ("$2")
    # pass straight through. No -L: a panel's landing-page redirect is inspected
    # by the caller, not auto-followed. --proto restricts to http/https.
    local tmp="${ECLIPVPN_TMP:-/tmp/eclipvpn}/.subfetch.$$"
    mkdir -p "${ECLIPVPN_TMP:-/tmp/eclipvpn}" 2>/dev/null
    local rc
    _router_fetch "$1" "$tmp" --proto '=http,https' \
        -A "EclipVPN/${ECLIPVPN_VERSION}" \
        -H "X-HWID: $hwid" -H "X-Device-OS: OpenWrt" \
        -H "X-Ver-OS: $os_ver" -H "X-Device-Model: $model" \
        --dump-header "$2"; rc=$?
    cat "$tmp" 2>/dev/null
    rm -f "$tmp"
    return "$rc"
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

    # $3 = subscription id, so meta (title/quota/expiry) is keyed per-provider
    # in subscription_meta.json (defaults to "default" for the legacy callers).
    _parse_subscription_headers "$hdr_file" "${3:-default}"
}

# Parse Profile-Title / Subscription-Userinfo / Announce / Profile-Update-Interval
# and write a single JSON to /tmp/eclipvpn/subscription_meta.json that cmd_status
# surfaces and the UI shows on the Settings tab.
_parse_subscription_headers() {
    local hdr_file="$1" sub_id="${2:-default}"
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
    local meta
    meta=$(jq -n \
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
        }')
    if [ -n "$meta" ]; then
        # Keyed by sub_id so several providers each keep their own quota/expiry.
        # A FLAT meta file (single {title,...,fetched_at}) from a pre-multi-
        # subscription build is detected and reset to {} before keying.
        ( umask 077
          mf=/tmp/eclipvpn/subscription_meta.json
          [ -f "$mf" ] || echo '{}' > "$mf"
          jq --arg id "$sub_id" --argjson m "$meta" \
             '(if (type=="object" and (has("fetched_at") or has("title"))) then {} else . end) | .[$id] = $m' \
             "$mf" > "$mf.tmp" 2>/dev/null && mv "$mf.tmp" "$mf" || rm -f "$mf.tmp" )
    fi
    rm -f "$hdr_file"
}

# --- selection remap + multi-sub merge (was in parse.sh) --------------------
# Keep the user's selected server pinned across a servers.json rebuild by
# IDENTITY (protocol+host+port+name), not by raw index — adding / removing /
# reordering / disabling a subscription shifts indices otherwise (a single
# provider reordering its own list already did, latently). Reads the CURRENT
# servers.json (pre-swap), finds the same server in $2 (the new merged array),
# rewrites config.selected_server. Clamps to 0 if the server vanished.
_remap_selected_server() {
    local config="$1" merged="$2"
    [ -f /tmp/eclipvpn/servers.json ] || return 0
    local sel; sel=$(jq -r '.selected_server // 0' "$config" 2>/dev/null)
    case "$sel" in ''|*[!0-9]*) return 0 ;; esac
    local cur; cur=$(jq -c --argjson i "$sel" '.[$i] // empty' /tmp/eclipvpn/servers.json 2>/dev/null)
    [ -z "$cur" ] && return 0
    local newidx
    newidx=$(printf '%s' "$merged" | jq --argjson c "$cur" '
        ([ .[] | (.protocol==($c.protocol) and .host==($c.host)
                  and .port==($c.port) and .name==($c.name)) ] | index(true)) // -1' 2>/dev/null)
    case "$newidx" in ''|*[!0-9-]*) return 0 ;; esac
    if [ "$newidx" -ge 0 ] 2>/dev/null; then
        if [ "$newidx" != "$sel" ]; then
            update_config '.selected_server = $i' --argjson i "$newidx" && logger -t eclipvpn "Subscription: remapped selected_server $sel -> $newidx (identity preserved)"
        fi
    else
        update_config '.selected_server = 0'
        logger -t eclipvpn "Subscription: selected server gone after refresh -> reset to index 0"
    fi
}

# Refresh every enabled subscription and merge into one server pool. Each
# provider is fetched into its OWN cache (sub.<id>.servers.json) with
# fetch-then-swap PER sub, so a single blocked/failed panel keeps its previous
# servers instead of dropping them from the pool. Servers are tagged with
# sub_id/sub_name (provenance, non-secret) and concatenated in config order.
# Echoes the total merged server count (0 ⇒ caller keeps the old servers.json).
update_subscription() {
    local config="$1"
    mkdir -p /tmp/eclipvpn

    # Persistent server-cache. /tmp is wiped on every reboot, so a subscription
    # whose panel host can't be fetched DIRECTLY (e.g. a vercel-hosted sub blocked
    # from RU) would come back EMPTY after a power-cycle. We mirror each parsed
    # per-sub cache to /etc (below) and restore any missing /tmp copy here, so the
    # LAST-known servers survive a reboot and the fetch-then-swap "keep previous
    # cache" path has something to keep. Periodic/manual updates still refresh them
    # (through the live tunnel via _sub_curl's SOCKS fallback when direct is blocked).
    _restore_subcache
    # Mirror destination for freshly-parsed caches (regressed once: the refactor
    # into _restore_subcache dropped this definition and the mirror cp silently
    # targeted "/" — nothing survived a reboot).
    local _scache; _scache="$(dirname "${ECLIPVPN_CONFIG:-/etc/eclipvpn/config.json}")/subcache"

    # Enabled subscriptions, in config order. Back-compat: an un-migrated config
    # reaching here directly falls back to the single legacy subscription_url.
    local subs
    subs=$(jq -c '
        if (.subscriptions|type)=="array" and ((.subscriptions|length)>0)
        then [ .subscriptions[] | select(.enabled != false) ]
        elif (.subscription_url // "") != ""
        then [ {id:"legacy", name:"Подписка", url:.subscription_url, enabled:true} ]
        else [] end' "$config" 2>/dev/null)
    [ -z "$subs" ] && subs="[]"
    local n; n=$(printf '%s' "$subs" | jq 'length' 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -eq 0 ]; then
        logger -t eclipvpn "Subscription: no enabled subscriptions configured"
        # No providers left → the merged pool is genuinely empty. Clear it so a
        # removed/disabled provider's servers don't linger in servers.json (and
        # keep showing in status / get probed by auto/failover). Safe mid-session:
        # the live tunnel runs off its already-generated xray/sing-box config;
        # servers.json is only read at config-generation time.
        [ -f /tmp/eclipvpn/servers.json ] && ( umask 077; echo '[]' > /tmp/eclipvpn/servers.json )
        echo 0; return 1
    fi

    local i=0
    while [ "$i" -lt "$n" ]; do
        local sid surl sname nauto
        sid=$(printf '%s' "$subs"  | jq -r --argjson i "$i" '.[$i].id')
        surl=$(printf '%s' "$subs" | jq -r --argjson i "$i" '.[$i].url')
        sname=$(printf '%s' "$subs" | jq -r --argjson i "$i" '.[$i].name // ""')
        # name_auto: true (default for legacy/migrated subs) ⇒ adopt the panel's
        # Profile-Title as the name; false ⇒ the user named it, never override.
        # NB: `.name_auto // true` is WRONG — jq's // treats the boolean false as
        # empty, so false//true → true and a user name would get clobbered. Read
        # it with an explicit `== false` test (same gotcha as auto_start).
        nauto=$(printf '%s' "$subs" | jq -r --argjson i "$i" 'if (.[$i].name_auto) == false then "false" else "true" end')
        i=$((i + 1))
        { [ -z "$sid" ] || [ "$sid" = "null" ] || [ -z "$surl" ] || [ "$surl" = "null" ]; } && continue
        surl=$(printf '%s' "$surl" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        # Manual-server sub: no fetch, no headers/meta — re-parse the URI locally
        # (cheap + deterministic; also self-heals a wiped /tmp cache). A parse
        # failure keeps the previous cache, same contract as a failed fetch.
        if _is_proxy_uri "$surl"; then
            _manual_sub_cache "$sid" "$surl" "$sname" \
                || logger -t eclipvpn "Subscription[$sname]: manual server URI failed to parse — keeping previous cache"
            continue
        fi
        local body="/tmp/eclipvpn/sub.$sid.body"
        local cache="/tmp/eclipvpn/sub.$sid.servers.json"
        local newc="/tmp/eclipvpn/sub.$sid.servers.new"
        if fetch_subscription "$surl" "$body" "$sid"; then
            # Take the name from the subscription itself (Profile-Title) unless
            # the user set one. _parse_subscription_headers already decoded any
            # `base64:`-prefixed title into subscription_meta[sub_id].title.
            if [ "$nauto" = "true" ]; then
                local title
                title=$(jq -r --arg id "$sid" '.[$id].title // ""' /tmp/eclipvpn/subscription_meta.json 2>/dev/null)
                if [ -n "$title" ] && [ "$title" != "null" ] && [ "$title" != "$sname" ]; then
                    sname="$title"
                    update_config '.subscriptions = ((.subscriptions // []) | map(if .id==$id then .name=$n else . end))' \
                        --arg id "$sid" --arg n "$title"
                    logger -t eclipvpn "Subscription[$sid]: name taken from panel title"
                fi
            fi
            local c; c=$(parse_subscription_file "$body" "$newc")
            if [ "$c" -gt 0 ] 2>/dev/null; then
                # Atomic write (.tmp + mv) — a truncated cache (e.g. power loss
                # mid-write) would otherwise pass the [ -s ] check in the merge
                # loop and abort jq there, collapsing the whole merged pool.
                ( umask 077; jq --arg sid "$sid" --arg sname "$sname" \
                    'map(. + {sub_id:$sid, sub_name:$sname})' "$newc" > "$cache.tmp" ) \
                    && mv "$cache.tmp" "$cache" || rm -f "$cache.tmp"
                chmod 600 "$cache" 2>/dev/null
                # Mirror to the persistent cache so these servers survive a reboot.
                # Atomic (.tmp + mv + sync): this mirror is the ONLY copy that
                # survives a power cut, so a cut mid-copy must not leave a
                # truncated file where the last-known server list used to be.
                if [ -s "$cache" ]; then
                    local _mbn; _mbn=$(basename "$cache")
                    if cp "$cache" "$_scache/$_mbn.tmp" 2>/dev/null \
                       && mv "$_scache/$_mbn.tmp" "$_scache/$_mbn" 2>/dev/null; then
                        chmod 600 "$_scache/$_mbn" 2>/dev/null
                        sync
                    else
                        rm -f "$_scache/$_mbn.tmp"
                    fi
                fi
            else
                logger -t eclipvpn "Subscription[$sname]: parsed 0 servers — keeping previous cache"
            fi
            rm -f "$newc"
        else
            logger -t eclipvpn "Subscription[$sname]: fetch failed — keeping previous cache"
        fi
        rm -f "$body"
    done

    # Merge enabled subs' caches (config order) into one pool.
    local merged="[]"
    i=0
    while [ "$i" -lt "$n" ]; do
        local sid; sid=$(printf '%s' "$subs" | jq -r --argjson i "$i" '.[$i].id'); i=$((i + 1))
        { [ -z "$sid" ] || [ "$sid" = "null" ]; } && continue
        local cache="/tmp/eclipvpn/sub.$sid.servers.json"
        # Skip a missing/corrupt cache rather than let jq abort and collapse the
        # whole merge: validate it's a JSON array, merge into a temp, and adopt
        # only if jq produced output (else keep the prior merged value).
        if [ -s "$cache" ] && jq -e 'type=="array"' "$cache" >/dev/null 2>&1; then
            local _m; _m=$(printf '%s' "$merged" | jq -c --slurpfile add "$cache" '. + $add[0]' 2>/dev/null)
            [ -n "$_m" ] && merged="$_m"
        fi
    done
    merged=$(printf '%s' "$merged" | _apply_server_filter | _apply_server_exclude)
    local count; count=$(printf '%s' "$merged" | jq 'length' 2>/dev/null)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac

    if [ "$count" -gt 0 ]; then
        _remap_selected_server "$config" "$merged"
        ( umask 077; printf '%s' "$merged" | jq '.' > /tmp/eclipvpn/servers.json.new ) \
            && mv /tmp/eclipvpn/servers.json.new /tmp/eclipvpn/servers.json
        chmod 600 /tmp/eclipvpn/servers.json 2>/dev/null
    fi
    echo "$count"
}

# Narrow a merged server pool by the optional `server_filter` config key — a
# comma-separated list of case-sensitive NAME substrings; a server is kept if its
# name contains ANY token. Empty/unset = no filtering. This keeps probe-driven
# failover/auto-select fast when a provider lists many servers that don't work
# from this network (e.g. only "WL" nodes pass the local whitelist): filtering
# the pool down to the working subset means the watchdog never spends minutes
# probing ~130 dead nodes before it lands on a live one.
#   - contains() is used, NOT test() — the router's jq is often built WITHOUT
#     Oniguruma (see parse.sh), so regex matchers error out.
#   - SAFETY: if the filter would leave 0 servers (typo, or a provider whose
#     names don't match), it is IGNORED and the unfiltered pool is returned, so a
#     bad filter can never silently empty servers.json and strand the tunnel.
# stdin: JSON array of servers; stdout: filtered (or original) JSON array.
_apply_server_filter() {
    local filt; filt=$(get_config_val server_filter "")
    [ -z "$filt" ] && { cat; return 0; }
    local input; input=$(cat)
    local out
    out=$(printf '%s' "$input" | jq -c --arg f "$filt" '
        ($f | split(",") | map(select(length>0))) as $toks
        | [ .[] | . as $s
            | select($toks | any(. as $t | ($s.name // "") | contains($t))) ]
    ' 2>/dev/null)
    if [ -n "$out" ] && [ "$(printf '%s' "$out" | jq 'length' 2>/dev/null)" -gt 0 ]; then
        printf '%s' "$out"
    else
        printf '%s' "$input"
    fi
}

# Drop servers matching the optional `server_exclude` config key — a
# comma-separated list of case-sensitive NAME substrings; a server is DROPPED
# if its name contains ANY token. The inverse of server_filter (which KEEPS
# only matches): for permanently decluttering a subscription's dead entries
# or confirmed-bad exits so they don't keep coming back on every `update` —
# deleting them from servers.json by hand doesn't survive the next merge,
# this does. Applied AFTER server_filter in the pipeline (filter narrows to a
# labelled subset first, e.g. WL; exclude then removes specific named entries
# from whatever's left).
#   - A "Russia"-named server is NOT necessarily a Russian EXIT — some relay
#     through a foreign host despite the name (e.g. measured 2026-09-15: one
#     "Russia MSK6" node's egress geolocated to Poland). Deciding what goes in
#     this list requires probing the actual egress IP (cmd_probe_server
#     already returns it), never name alone — see CLAUDE.md.
#   - contains(), not test() — same Oniguruma-less jq as everywhere else.
#   - SAFETY: if excluding would empty the pool, it's IGNORED (same guard as
#     server_filter) — a typo or an over-broad token can never silently
#     strand the tunnel with 0 servers.
# stdin: JSON array; stdout: filtered (or original) JSON array.
_apply_server_exclude() {
    local excl; excl=$(get_config_val server_exclude "")
    [ -z "$excl" ] && { cat; return 0; }
    local input; input=$(cat)
    local out
    out=$(printf '%s' "$input" | jq -c --arg f "$excl" '
        ($f | split(",") | map(select(length>0))) as $toks
        | [ .[] | . as $s
            | select(($toks | any(. as $t | ($s.name // "") | contains($t))) | not) ]
    ' 2>/dev/null)
    if [ -n "$out" ] && [ "$(printf '%s' "$out" | jq 'length' 2>/dev/null)" -gt 0 ]; then
        printf '%s' "$out"
    else
        printf '%s' "$input"
    fi
}

# Restore the PERSISTENT /etc subcache into /tmp (wiped on reboot) so the offline
# merge and the fetch-then-swap "keep previous cache" path have the last-known
# per-sub servers to work with. Idempotent: only fills a MISSING /tmp copy, never
# clobbers a fresher one. No network. Called at the top of update_subscription
# AND directly by cmd_start for the cold-boot offline path.
_restore_subcache() {
    local scache; scache="$(dirname "${ECLIPVPN_CONFIG:-/etc/eclipvpn/config.json}")/subcache"
    local tmp="${ECLIPVPN_TMP:-/tmp/eclipvpn}"
    mkdir -p "$scache" "$tmp" 2>/dev/null
    local pf bn
    for pf in "$scache"/sub.*.servers.json; do
        [ -e "$pf" ] || continue
        bn=$(basename "$pf")
        [ -s "$tmp/$bn" ] || { cp "$pf" "$tmp/$bn" 2>/dev/null; chmod 600 "$tmp/$bn" 2>/dev/null; }
    done
}

# Re-merge the enabled subs' EXISTING per-sub caches into servers.json with NO
# network fetch and NO rule refresh — for `sub enable/disable/remove`, which only
# change WHICH providers are in the pool, not their contents. Mirrors
# update_subscription's merge phase (incl. the n==0 → clear and the count>0 swap
# guard). Echoes the merged server count.
_merge_sub_pool() {
    local config="$1"
    local tmp="${ECLIPVPN_TMP:-/tmp/eclipvpn}"
    mkdir -p "$tmp"
    local subs n
    subs=$(jq -c 'if (.subscriptions|type)=="array" and ((.subscriptions|length)>0)
                  then [ .subscriptions[] | select(.enabled != false) ]
                  elif (.subscription_url // "") != ""
                  then [ {id:"legacy", url:.subscription_url} ]
                  else [] end' "$config" 2>/dev/null)
    [ -z "$subs" ] && subs="[]"
    n=$(printf '%s' "$subs" | jq 'length' 2>/dev/null); case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -eq 0 ]; then
        [ -f "$tmp/servers.json" ] && ( umask 077; echo '[]' > "$tmp/servers.json" )
        echo 0; return 0
    fi
    local merged="[]" i=0
    while [ "$i" -lt "$n" ]; do
        local sid surl
        sid=$(printf '%s' "$subs" | jq -r --argjson i "$i" '.[$i].id')
        surl=$(printf '%s' "$subs" | jq -r --argjson i "$i" '.[$i].url // ""')
        i=$((i + 1))
        { [ -z "$sid" ] || [ "$sid" = "null" ]; } && continue
        local cache="$tmp/sub.$sid.servers.json"
        # A manual-server sub carries its whole "subscription" in the url — a
        # missing cache (fresh /tmp, no subcache mirror) is rebuilt right here,
        # offline, so manual servers can never vanish from the pool.
        if [ ! -s "$cache" ] && _is_proxy_uri "$surl"; then
            local sname; sname=$(printf '%s' "$subs" | jq -r --argjson i "$((i - 1))" '.[$i].name // ""')
            _manual_sub_cache "$sid" "$surl" "$sname" || true
        fi
        if [ -s "$cache" ] && jq -e 'type=="array"' "$cache" >/dev/null 2>&1; then
            local _m; _m=$(printf '%s' "$merged" | jq -c --slurpfile add "$cache" '. + $add[0]' 2>/dev/null)
            [ -n "$_m" ] && merged="$_m"
        fi
    done
    merged=$(printf '%s' "$merged" | _apply_server_filter | _apply_server_exclude)
    local count; count=$(printf '%s' "$merged" | jq 'length' 2>/dev/null); case "$count" in ''|*[!0-9]*) count=0 ;; esac
    if [ "$count" -gt 0 ]; then
        _remap_selected_server "$config" "$merged"
        ( umask 077; printf '%s' "$merged" | jq '.' > "$tmp/servers.json.new" ) \
            && mv "$tmp/servers.json.new" "$tmp/servers.json"
        chmod 600 "$tmp/servers.json" 2>/dev/null
    fi
    echo "$count"
}

# --- management command (was in config.sh) ----------------------------------
# Multi-subscription manager. Subscriptions live in config.subscriptions[];
# servers from every enabled one are merged into the flat servers.json by
# update_subscription (parse.sh), tagged with sub_id/sub_name. `subscription_url`
# is kept mirrored to subscriptions[0] for back-compat. cmd_update applies
# changes (re-fetch + soft restart; the fast path no-ops if the selected
# server's config is unchanged, so adding a 2nd provider doesn't drop the tunnel).
cmd_sub() {
    local op="${1:-list}" arg2="${2:-}" arg3="${3:-}"
    case "$op" in
        list)
            local meta='{}' counts='{}'
            [ -f "$ECLIPVPN_TMP/subscription_meta.json" ] && \
                meta=$(jq '.' "$ECLIPVPN_TMP/subscription_meta.json" 2>/dev/null || echo '{}')
            [ -f "$ECLIPVPN_TMP/servers.json" ] && \
                counts=$(jq '[.[].sub_id // "?"] | group_by(.) | map({key:.[0], value:length}) | from_entries' \
                    "$ECLIPVPN_TMP/servers.json" 2>/dev/null || echo '{}')
            jq --argjson meta "$meta" --argjson counts "$counts" \
               '{subscriptions: ((.subscriptions // [])
                    | map(. + {server_count: ($counts[.id] // 0), meta: ($meta[.id] // null)}))}' \
               "$ECLIPVPN_CONFIG"
            ;;
        add)
            local url="$arg2" name="$arg3"
            [ -z "$url" ] && { echo '{"error":"url required"}'; return 1; }
            url=$(printf '%s' "$url" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            local manual=0
            case "$url" in
                https://*|http://*) ;;
                *) _is_proxy_uri "$url" && manual=1 \
                       || { echo '{"error":"url must start with http(s):// or be a vless/vmess/trojan/ss/hysteria2 server URI"}'; return 1; }
                   ;;
            esac
            local id; id=$(_sub_id_for_url "$url")
            [ -z "$id" ] && { echo '{"error":"could not derive id"}'; return 1; }
            # Manual server: parse BEFORE saving anything, so a broken URI fails
            # fast instead of leaving a dead entry. Default name = the server's
            # own #fragment name; name_auto=false always (there is no panel
            # title to adopt later).
            local srv=""
            if [ "$manual" = "1" ]; then
                srv=$(parse_proxy_url "$url") && [ -n "$srv" ] \
                    || { echo '{"error":"could not parse server URI — check the link"}'; return 1; }
                [ -z "$name" ] && name=$(printf '%s' "$srv" | jq -r '.name // ""' 2>/dev/null)
            fi
            # Idempotent by id. A user-supplied name pins name_auto=false (never
            # overridden by the panel title); no name ⇒ a placeholder + name_auto
            # =true, so update_subscription adopts the Profile-Title on fetch.
            # subscription_url (legacy mirror) tracks the first FETCHABLE sub —
            # a manual vless:// URI is not a subscription URL for old consumers.
            update_config '
                .subscriptions = ((.subscriptions // []) as $s
                    | if ($s | map(.id) | index($id)) then
                        ($s | map(if .id==$id
                                  then (.url=$url | .enabled=true | (if $name!="" then (.name=$name | .name_auto=false) else . end))
                                  else . end))
                      else
                        ($s + [{id:$id,
                                name:(if $name!="" then $name else "Подписка \(($s|length)+1)" end),
                                url:$url, enabled:true,
                                name_auto:($name=="" and $manual=="0"),
                                manual:($manual=="1")}])
                      end)
                | .subscription_url = (([.subscriptions[] | select((.url // "") | startswith("http"))] | .[0].url) // "")' \
                --arg id "$id" --arg url "$url" --arg name "$name" --arg manual "$manual" \
                || { echo '{"error":"save failed"}'; return 1; }
            if [ "$manual" = "1" ]; then
                # No fetch needed — build the single-server cache locally and
                # re-merge offline (same cheap path as enable/remove).
                _manual_sub_cache "$id" "$url" "$name" || { echo '{"error":"could not parse server URI — check the link"}'; return 1; }
                local newc; newc=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
                [ "${newc:-0}" -gt 0 ] 2>/dev/null && _vpn_running && cmd_restart >/dev/null 2>&1
            else
                cmd_update >/dev/null 2>&1
            fi
            jq -n --arg id "$id" --argjson m "$([ "$manual" = "1" ] && echo true || echo false)" \
                '{status:"added", id:$id, manual:$m}'
            ;;
        remove)
            local id="$arg2"; [ -z "$id" ] && { echo '{"error":"id required"}'; return 1; }
            update_config '.subscriptions = ((.subscriptions // []) | map(select(.id != $id)))
                 | .subscription_url = (([.subscriptions[] | select((.url // "") | startswith("http"))] | .[0].url) // "")' \
                --arg id "$id" || { echo '{"error":"save failed"}'; return 1; }
            rm -f "$ECLIPVPN_TMP/sub.$id.servers.json" "$ECLIPVPN_TMP/sub.$id.servers.json.tmp" "$ECLIPVPN_TMP/sub.$id.body" "$ECLIPVPN_TMP/sub.$id.servers.new"
            # Drop the PERSISTENT mirror too (see update_subscription's subcache):
            # otherwise the removed provider's last servers survive a reboot in
            # /etc/.../subcache, get restored into /tmp, and a later re-add of the
            # same URL (same id) briefly shows stale nodes before the fresh fetch.
            rm -f "$(dirname "${ECLIPVPN_CONFIG:-/etc/eclipvpn/config.json}")/subcache/sub.$id.servers.json"
            # Prune the provider's keyed metadata too, so removed subs don't leak
            # dead entries in subscription_meta.json (atomic write).
            local mf="$ECLIPVPN_TMP/subscription_meta.json"
            [ -f "$mf" ] && { jq --arg id "$id" 'del(.[$id])' "$mf" > "$mf.tmp" 2>/dev/null && mv "$mf.tmp" "$mf" || rm -f "$mf.tmp"; }
            # No fetch needed — the provider is gone; re-merge the remaining caches
            # (cheap, offline) instead of cmd_update re-fetching everyone + rules.
            local newc; newc=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
            [ "${newc:-0}" -gt 0 ] 2>/dev/null && _vpn_running && cmd_restart >/dev/null 2>&1
            jq -n --arg id "$id" '{status:"removed", id:$id}'
            ;;
        enable|disable)
            local id="$arg2"; [ -z "$id" ] && { echo '{"error":"id required"}'; return 1; }
            local en=false; [ "$op" = "enable" ] && en=true
            update_config '.subscriptions = ((.subscriptions // []) | map(if .id==$id then .enabled=$en else . end))' \
                --arg id "$id" --argjson en "$en" || { echo '{"error":"save failed"}'; return 1; }
            # A toggle only changes WHICH providers are in the pool, not their
            # contents — so re-merge the existing per-sub caches instead of a full
            # cmd_update, which re-fetches every enabled provider AND re-downloads
            # the geosite/blocklist rule sets over the network (slow; the .srs
            # force-download routinely hangs on RU-blocked raw.githubusercontent).
            # The disabled provider's cache is KEPT so re-enabling stays instant —
            # the merge reads enabled subs only, so it's excluded regardless. Only
            # fall back to a real fetch when enabling a sub whose cache is absent.
            local newc
            if [ "$op" = "enable" ] && [ ! -s "$ECLIPVPN_TMP/sub.$id.servers.json" ]; then
                cmd_update >/dev/null 2>&1
            else
                newc=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
                [ "${newc:-0}" -gt 0 ] 2>/dev/null && _vpn_running && cmd_restart >/dev/null 2>&1
            fi
            jq -n --arg id "$id" --arg s "$op" '{status:$s, id:$id}'
            ;;
        rename)
            local id="$arg2" name="$arg3"
            { [ -z "$id" ] || [ -z "$name" ]; } && { echo '{"error":"id and name required"}'; return 1; }
            # name_auto=false pins this name so a later update won't replace it
            # with the panel's Profile-Title.
            update_config '.subscriptions = ((.subscriptions // []) | map(if .id==$id then (.name=$name | .name_auto=false) else . end))' \
                --arg id "$id" --arg name "$name" || { echo '{"error":"save failed"}'; return 1; }
            # Rename is purely cosmetic (sub_name tag) — re-tag the per-sub cache
            # and the merged servers.json IN PLACE instead of re-fetching every
            # provider over the network. No restart: server identities unchanged.
            local cache="$ECLIPVPN_TMP/sub.$id.servers.json"
            if [ -s "$cache" ]; then
                jq --arg n "$name" 'map(.sub_name=$n)' "$cache" > "$cache.t" 2>/dev/null \
                    && mv "$cache.t" "$cache" && chmod 600 "$cache" 2>/dev/null || rm -f "$cache.t"
            fi
            local sf="$ECLIPVPN_TMP/servers.json"
            if [ -s "$sf" ]; then
                jq --arg id "$id" --arg n "$name" 'map(if .sub_id==$id then .sub_name=$n else . end)' "$sf" > "$sf.t" 2>/dev/null \
                    && mv "$sf.t" "$sf" && chmod 600 "$sf" 2>/dev/null || rm -f "$sf.t"
            fi
            jq -n --arg id "$id" --arg n "$name" '{status:"renamed", id:$id, name:$n}'
            ;;
        *) jq -n --arg op "$op" '{error:("unknown op: "+$op+" (use list/add/remove/enable/disable/rename)")}'; return 1 ;;
    esac
}
