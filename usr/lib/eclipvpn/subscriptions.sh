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

# --- management command (was in config.sh) ----------------------------------
# Multi-subscription manager. Subscriptions live in config.subscriptions[];
# servers from every enabled one are merged into the flat servers.json by
# update_subscription (parse.sh), tagged with sub_id/sub_name. `subscription_url`
# is kept mirrored to subscriptions[0] for back-compat. cmd_update applies
# changes (re-fetch + soft restart; the fast path no-ops if the selected
# server's config is unchanged, so adding a 2nd provider doesn't drop the tunnel).
cmd_sub() {
    local op="${1:-list}" arg2="$2" arg3="$3"
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
            case "$url" in https://*|http://*) ;; *) echo '{"error":"url must start with http:// or https://"}'; return 1 ;; esac
            url=$(printf '%s' "$url" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            local id; id=$(_sub_id_for_url "$url")
            [ -z "$id" ] && { echo '{"error":"could not derive id"}'; return 1; }
            # Idempotent by id. A user-supplied name pins name_auto=false (never
            # overridden by the panel title); no name ⇒ a placeholder + name_auto
            # =true, so update_subscription adopts the Profile-Title on fetch.
            update_config '
                .subscriptions = ((.subscriptions // []) as $s
                    | if ($s | map(.id) | index($id)) then
                        ($s | map(if .id==$id
                                  then (.url=$url | .enabled=true | (if $name!="" then (.name=$name | .name_auto=false) else . end))
                                  else . end))
                      else
                        ($s + [{id:$id,
                                name:(if $name!="" then $name else "Подписка \(($s|length)+1)" end),
                                url:$url, enabled:true, name_auto:($name=="")}])
                      end)
                | .subscription_url = ((.subscriptions[0].url) // "")' \
                --arg id "$id" --arg url "$url" --arg name "$name" || { echo '{"error":"save failed"}'; return 1; }
            cmd_update >/dev/null 2>&1
            jq -n --arg id "$id" '{status:"added", id:$id}'
            ;;
        remove)
            local id="$arg2"; [ -z "$id" ] && { echo '{"error":"id required"}'; return 1; }
            update_config '.subscriptions = ((.subscriptions // []) | map(select(.id != $id)))
                 | .subscription_url = ((.subscriptions[0].url) // "")' \
                --arg id "$id" || { echo '{"error":"save failed"}'; return 1; }
            rm -f "$ECLIPVPN_TMP/sub.$id.servers.json" "$ECLIPVPN_TMP/sub.$id.servers.json.tmp" "$ECLIPVPN_TMP/sub.$id.body" "$ECLIPVPN_TMP/sub.$id.servers.new"
            # Prune the provider's keyed metadata too, so removed subs don't leak
            # dead entries in subscription_meta.json (atomic write).
            local mf="$ECLIPVPN_TMP/subscription_meta.json"
            [ -f "$mf" ] && { jq --arg id "$id" 'del(.[$id])' "$mf" > "$mf.tmp" 2>/dev/null && mv "$mf.tmp" "$mf" || rm -f "$mf.tmp"; }
            cmd_update >/dev/null 2>&1
            jq -n --arg id "$id" '{status:"removed", id:$id}'
            ;;
        enable|disable)
            local id="$arg2"; [ -z "$id" ] && { echo '{"error":"id required"}'; return 1; }
            local en=false; [ "$op" = "enable" ] && en=true
            update_config '.subscriptions = ((.subscriptions // []) | map(if .id==$id then .enabled=$en else . end))' \
                --arg id "$id" --argjson en "$en" || { echo '{"error":"save failed"}'; return 1; }
            # Drop a disabled provider's cache so its servers leave the pool now.
            [ "$op" = "disable" ] && rm -f "$ECLIPVPN_TMP/sub.$id.servers.json"
            cmd_update >/dev/null 2>&1
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
        *) echo "{\"error\":\"unknown op: $op (use list/add/remove/enable/disable/rename)\"}"; return 1 ;;
    esac
}
