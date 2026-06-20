#!/bin/ash
# EclipVPN v3 — sing-box config generator
# Mode "all_vpn": everything through VPN, RU domains direct
# Mode "blocklist": only blocked domains through VPN (Shadowrocket lists)

# Derived from the overridable base paths (set in usr/bin/eclipvpn BEFORE the
# libs are sourced) so the test harness's ECLIPVPN_TMP/ECLIPVPN_CONFIG sandbox
# also redirects rule writes, never the live /tmp or /etc. Same lesson as the
# network.sh bare-assignment bug (b81ad0c) that let the suite clobber prod.
SR_RULES_DIR="${ECLIPVPN_TMP:-/tmp/eclipvpn}/rules"
RULESET_DIR="$(dirname "${ECLIPVPN_CONFIG:-/etc/eclipvpn/config.json}")/rules"
CUSTOM_DIRECT="/etc/eclipvpn/direct_domains.txt"
CUSTOM_VPN="/etc/eclipvpn/vpn_domains.txt"

GEOSITE_RU_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs"
GEOIP_RU_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/ru.srs"


# ============================================================
# Convert Shadowrocket rules to sing-box format
# ============================================================

convert_sr_to_singbox_rule() {
    # Build the rule via jq so that arbitrary content from the downloaded
    # rule file (which we don't control — comes from GitHub) cannot break
    # or inject into the JSON. Values are passed as raw lines and jq does
    # the string escaping.
    local file="$1"
    awk -F, '
        /^#/ || /^$/ { next }
        $1 == "DOMAIN-SUFFIX"  { print "ds\t" $2; next }
        $1 == "DOMAIN-KEYWORD" { print "dk\t" $2; next }
        $1 == "DOMAIN"         { print "d\t"  $2; next }
        $1 == "IP-CIDR" || $1 == "IP-CIDR6" { print "ip\t" $2; next }
    ' "$file" | \
    jq -R -s '
        [split("\n")[] | select(length > 0) | split("\t") | {kind: .[0], val: .[1]}] as $items |
        {
            domain_suffix:  [$items[] | select(.kind=="ds") | .val],
            domain_keyword: [$items[] | select(.kind=="dk") | .val],
            domain:         [$items[] | select(.kind=="d")  | .val],
            ip_cidr:        [$items[] | select(.kind=="ip") | .val]
        } |
        with_entries(select(.value | length > 0)) |
        if length == 0 then empty else . end
    '
}

convert_ip_list() {
    local file="$1"
    awk -F, '/^IP-CIDR/ { sub(/^IP-CIDR,/,""); split($0,a,","); if(a[1] ~ /^[0-9]/) print a[1] }' "$file" | \
    jq -R -s '[split("\n")[] | select(length > 0)] |
              if length == 0 then empty else {ip_cidr: .} end'
}

# ============================================================
# Native sing-box proxy outbounds (multi-protocol)
# ============================================================
# xray can't speak QUIC, so hysteria2 (and future tuic/wireguard) are dialed
# by sing-box itself. These builders produce the "default" outbound and the
# throwaway dialer configs the probe/failover paths use — mirroring the
# throwaway-xray flow so the rest of the machinery stays engine-agnostic.

# Build the NATIVE sing-box proxy outbound (tag "default") for server $2 of $1
# (servers.json). Echoes the outbound JSON; returns 1 on bad index / proto with
# no builder. routing_mark 32768 stamps the exit's QUIC packets with fwmark
# 0x8000 so the eclipvpn nft chain's anti-loop rule lets them out the WAN (the
# same exemption xray gets via sockopt mark; route.default_mark backstops it).
_singbox_proxy_outbound() {
    local servers_file="$1" idx="$2" server proto
    server=$(jq -c --argjson i "$idx" '.[$i]' "$servers_file" 2>/dev/null)
    [ -z "$server" ] || [ "$server" = "null" ] && { flog "ERROR: sing-box outbound: server index $idx not found"; return 1; }
    proto=$(printf '%s' "$server" | jq -r '.protocol // "vless"')
    case "$proto" in
        hysteria2)
            # server/server_port/password/tls required; obfs + insecure optional.
            printf '%s' "$server" | jq '
                {
                    type: "hysteria2",
                    tag: "default",
                    server: .host,
                    server_port: .port,
                    password: .password,
                    tls: ({ enabled: true,
                            server_name: (if (.sni // "") != "" then .sni else .host end) }
                          + (if ((.insecure // 0) == 1) or ((.insecure // false) == true)
                             then { insecure: true } else {} end)),
                    routing_mark: 32768
                }
                + (if (.obfs // "") != "" and (.obfs_pw // "") != ""
                   then { obfs: { type: .obfs, password: .obfs_pw } } else {} end)
            '
            ;;
        *)
            flog "ERROR: sing-box engine has no outbound builder for protocol '$proto'"
            return 1
            ;;
    esac
}

# Throwaway sing-box "dialer" config for probing candidate server $1 on a temp
# SOCKS port $2, written to $3. Mirrors cmd_probe_server's throwaway-xray:
# socks inbound → native proxy outbound, no routing rules (a clean measurement).
# A tiny dns+direct pair resolves the server host when it's an FQDN (panel hy2
# hosts are domains). Returns non-zero if the config couldn't be written.
_gen_hysteria2_probe() {
    local idx="$1" port="$2" out="$3" hy2
    hy2=$(_singbox_proxy_outbound "$ECLIPVPN_TMP/servers.json" "$idx") || return 1
    hy2=$(printf '%s' "$hy2" | jq '.tag = "proxy"')
    jq -n --argjson port "$port" --argjson hy2 "$hy2" '{
        log: { level: "error" },
        dns: { servers: [ { tag: "d", type: "udp", server: "77.88.8.8", detour: "direct-out" } ] },
        inbounds: [ { type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: $port } ],
        outbounds: [ $hy2, { type: "direct", tag: "direct-out", routing_mark: 32768 } ],
        route: { default_domain_resolver: "d", default_mark: 32768, final: "proxy" }
    }' > "$out" 2>/dev/null
    [ -s "$out" ]
}

# Engine-agnostic probe-config generator. Picks the right engine for server $1,
# writes a throwaway socks-on-$2 config to $3, and ECHOES the engine name
# ("xray"|"singbox") so the caller spawns the matching binary (xray uses
# `run -config FILE`; sing-box uses `run -c FILE`). Returns 1 on failure.
_gen_probe_config() {
    local idx="$1" port="$2" out="$3" proto eng
    proto=$(_server_protocol "$idx")
    eng=$(_engine_for_protocol "$proto")
    if [ "$eng" = "singbox" ]; then
        _gen_hysteria2_probe "$idx" "$port" "$out" || return 1
    else
        local base="${out}.base"
        generate_xray_config "$ECLIPVPN_TMP/servers.json" "$idx" "$base" || { rm -f "$base"; return 1; }
        jq --argjson p "$port" \
            '.inbounds=[{tag:"t",port:$p,listen:"127.0.0.1",protocol:"socks",settings:{auth:"noauth"}}]' \
            "$base" > "$out" 2>/dev/null || { rm -f "$base"; return 1; }
        rm -f "$base"
    fi
    echo "$eng"
}

# ============================================================
# Generate sing-box config
# ============================================================

# Args: OUTPUT MODE SERVERS_FILE SEL_IDX [SOCKS_PORT=1080]. SERVERS_FILE+SEL_IDX
# pick the proxy engine for the selected server (see the engine helpers in
# usr/bin/eclipvpn); omitting them defaults to the xray engine. SOCKS_PORT is the
# port of the xray SOCKS frontend the "default" outbound dials — usually 1080,
# but make-before-break stages the new xray on the alternate port and points the
# new sing-box config at it (the active xray port rotates 1080<->1081; see
# _active_socks_port). Ignored for the hysteria2 engine (sing-box dials natively).
generate_singbox_config() {
    local output="$1" mode="$2" servers_file="$3" sel_idx="$4" socks_port="${5:-1080}"

    # Sing-box reads geosite-ru/geoip-ru as local files (see rule_set block
    # below). They MUST exist or sing-box refuses to start. Cached files from a
    # prior run are reused; only the first install pays the curl-retry cost.
    # If the fetch fails and there's no cache, _ensure_srs_present compiles an
    # empty .srs so the VPN still comes up (degraded RU routing) instead of
    # failing to start entirely.
    _fetch_rule_sets || flog "WARN: rule-set fetch failed; relying on cache or empty fallback"
    _ensure_srs_present

    # Pick the proxy engine for the selected server. xray engine: "default"
    # outbound is socks→xray:1080 (xray owns the SOCKS frontend), no socks
    # inbound here. sing-box engine (hysteria2): sing-box dials the exit
    # natively as "default" AND exposes its own SOCKS:1080, so xray is not run
    # and every probe/health path that curls 127.0.0.1:1080 keeps working.
    local proto engine proxy_outbound socks_inbound="null"
    proto="vless"
    if [ -n "$servers_file" ] && [ -f "$servers_file" ] && [ -n "$sel_idx" ]; then
        proto=$(jq -r --argjson i "$sel_idx" '(.[$i].protocol // "vless")' "$servers_file" 2>/dev/null)
        [ -z "$proto" ] && proto="vless"
    fi
    engine=$(_engine_for_protocol "$proto")
    if [ "$engine" = "singbox" ]; then
        proxy_outbound=$(_singbox_proxy_outbound "$servers_file" "$sel_idx") \
            || { flog "ERROR: could not build native sing-box outbound for $proto"; return 1; }
        socks_inbound='{"type":"socks","tag":"socks-in","listen":"127.0.0.1","listen_port":1080}'
    else
        proxy_outbound=$(jq -n --argjson p "$socks_port" '{type:"socks",tag:"default",server:"127.0.0.1",server_port:$p,version:"5"}')
    fi

    local rules dns_rules

    if [ "$mode" = "all_vpn" ]; then
        _build_allvpn_rules
    else
        _build_blocklist_rules
    fi

    # When sing-box owns SOCKS:1080 (hysteria2), pin that inbound to "default"
    # so probes measure the tunnel REGARDLESS of mode — in blocklist mode a
    # generic probe (api.ipify.org) would otherwise route direct and falsely
    # "succeed" without exercising the tunnel. Scoped to the socks-in inbound,
    # so LAN tproxy traffic still follows the mode rules. Inserted right after
    # the sniff rule (index 0), before the mode/RU rules.
    if [ "$engine" = "singbox" ]; then
        rules=$(printf '%s' "$rules" | jq -c '.[0:1] + [{"inbound":["socks-in"],"outbound":"default"}] + .[1:]')
    fi

    local clash_secret
    clash_secret=$(_get_clash_secret)

    # Build full config.
    # Note on default_domain_resolver: sing-box 1.12+ requires an explicit
    # DNS resolver for outbound dial (else logs WARN, 1.14 refuses to start).
    # We point it at dns-direct (1.1.1.1 udp via direct outbound) — outbounds
    # mostly dial pre-resolved IPs anyway (subscription has host IPs, sing-box
    # DNS rules resolve domains before dial), so this matters mainly for
    # internals and remote rule_set fetches over the "direct" path.
    jq -n \
        --argjson rules "$rules" \
        --argjson dns_rules "$dns_rules" \
        --argjson proxy_outbound "$proxy_outbound" \
        --argjson socks_inbound "$socks_inbound" \
        --arg clash_secret "$clash_secret" \
        --arg final_outbound "$([ "$mode" = "all_vpn" ] && echo "default" || echo "direct")" \
        --arg final_dns "$([ "$mode" = "all_vpn" ] && echo "dns-proxy" || echo "dns-direct")" \
        --arg loglevel "$(get_config_val singbox_loglevel info)" \
    '{
        log: {level: $loglevel, timestamp: true},
        experimental: {
            cache_file: {enabled: true, path: "/tmp/eclipvpn/cache.db"},
            clash_api: {external_controller: "127.0.0.1:9090", secret: $clash_secret}
        },
        dns: {
            servers: [
                {tag: "dns-proxy", type: "https", server: "1.1.1.1", server_port: 443, path: "/dns-query", detour: "default"},
                # dns-direct uses Yandex DNS, not Cloudflare 1.1.1.1: VTB and some
                # other RU banks have authoritative NS configured to refuse foreign
                # resolvers, so 1.1.1.1 returns SERVFAIL for www.vtb.ru. Yandex
                # also returns RU-locality CDN IPs for the same hostname, which
                # resolves faster from inside RU than the foreign-pinned answer.
                {tag: "dns-direct", type: "udp", server: "77.88.8.8", detour: "direct"},
                {tag: "dns-block", type: "udp", server: "127.0.0.127"}
            ],
            rules: $dns_rules,
            final: $final_dns,
            strategy: "ipv4_only"
        },
        inbounds: ([
            {type: "tproxy", tag: "tproxy-in", listen: "::", listen_port: 2154},
            {type: "direct", tag: "dns-in", listen: "127.0.0.1", listen_port: 5354}
        ] + (if $socks_inbound == null then [] else [$socks_inbound] end)),
        outbounds: [
            {type: "direct", tag: "direct", routing_mark: 32768},
            $proxy_outbound
        ],
        route: {
            default_domain_resolver: "dns-direct",
            default_mark: 32768,
            rules: $rules,
            rule_set: [
                {type: "local", tag: "geosite-ru", format: "binary",
                 path: "/etc/eclipvpn/rules/geosite-category-ru.srs"},
                {type: "local", tag: "geoip-ru", format: "binary",
                 path: "/etc/eclipvpn/rules/ru.srs"}
            ],
            final: $final_outbound,
            auto_detect_interface: true
        }
    }' > "$output" || { flog "ERROR: failed to generate sing-box config (jq)"; return 1; }
    # A truncated/empty output here would otherwise be reported as success and
    # sing-box would fail to start with a misleading message.
    [ -s "$output" ] || { flog "ERROR: generated sing-box config is empty"; return 1; }
    # sing-box config holds the Clash API secret; tighten file mode.
    chmod 600 "$output" 2>/dev/null
}

_build_allvpn_rules() {
    # Mode: everything through VPN, RU domains direct — UNLESS full_tunnel=true,
    # which drops the RU→direct rules (route + DNS) so EVERYTHING (incl. RU banks)
    # rides the VPN. Needed where the direct path can't actually reach RU services:
    # e.g. behind an upstream router that doesn't route major RU subnets (observed
    # 2026-06-20 — Sberbank's 84.252.x was unreachable direct but fine via the VPN
    # exit, so RU-direct stranded banks while full-tunnel fixed them).
    local full_tunnel; full_tunnel=$(get_config_val full_tunnel false)

    local ru_rule=""
    [ -f "$SR_RULES_DIR/ru_domains.list" ] && ru_rule=$(convert_sr_to_singbox_rule "$SR_RULES_DIR/ru_domains.list")

    # Force-VPN domains (built-in AI services + user's custom_vpn).
    # _fetch_vpn_domains rebuilds vpn_domains.list on every fetch_rules and
    # on every add-domain/remove-domain. We funnel the file through jq so
    # any quote/backslash in a user-added domain becomes properly-escaped
    # JSON instead of breaking the rule string we hand to sing-box.
    local vpn_rule=""
    if [ -f "$SR_RULES_DIR/vpn_domains.list" ]; then
        vpn_rule=$(tr -d '\r' < "$SR_RULES_DIR/vpn_domains.list" | grep -vE '^(#|$)' \
            | jq -R -s '[split("\n")[] | select(length > 0)]
                        | if length == 0 then null else {domain_suffix: .} end')
        [ "$vpn_rule" = "null" ] && vpn_rule=""
    fi

    # Force-DIRECT whitelist: the user's CUSTOM_DIRECT file (direct_domains.txt),
    # built inline as domain_suffix (NOT the broad ru_domains.list). Honoured even
    # under full_tunnel — there it's the ONLY thing allowed to bypass the VPN, for
    # RU services that need a RU residential IP AND are reachable on the direct
    # path (e.g. Kinopoisk/Okko/wink streaming, which a foreign VPN exit geo-blocks
    # while RU banks on un-routable subnets must stay on the VPN). In normal
    # all_vpn these domains are already covered by ru_rule, so this only adds the
    # extra direct rule when full_tunnel is on.
    local direct_rule=""
    if [ -f "$CUSTOM_DIRECT" ]; then
        direct_rule=$(tr -d '\r' < "$CUSTOM_DIRECT" | grep -vE '^(#|$)' \
            | jq -R -s '[split("\n")[] | select(length > 0)]
                        | if length == 0 then null else {domain_suffix: .} end')
        [ "$direct_rule" = "null" ] && direct_rule=""
    fi

    # Route rules:
    # 1. sniff
    # 2. hijack DNS
    # 3. reject DoT (853)
    # 4. reject QUIC (UDP 443)
    # 5. custom VPN domains → VPN (before RU rules)
    # 6. geosite-ru + geoip-ru + manual RU → direct
    # 7. final → VPN (default)
    rules="[{\"action\":\"sniff\",\"timeout\":\"300ms\"}"
    rules="$rules,{\"type\":\"logical\",\"mode\":\"or\",\"rules\":[{\"protocol\":\"dns\"},{\"port\":[53]}],\"action\":\"hijack-dns\"}"
    rules="$rules,{\"port\":[853],\"action\":\"reject\"}"
    rules="$rules,{\"network\":[\"udp\"],\"port\":[443],\"action\":\"reject\"}"

    # Custom VPN domains (force through VPN)
    if [ -n "$vpn_rule" ]; then
        rules="$rules,$(echo "$vpn_rule" | jq '. + {outbound:"default"}')"
    fi

    # RU traffic → direct (geosite + geoip + manual list) — skipped in full_tunnel
    # so RU falls through to the default VPN outbound.
    if [ "$full_tunnel" != "true" ]; then
        rules="$rules,{\"rule_set\":[\"geosite-ru\",\"geoip-ru\"],\"outbound\":\"direct\"}"
        if [ -n "$ru_rule" ]; then
            rules="$rules,$(echo "$ru_rule" | jq '. + {outbound:"direct"}')"
        fi
    elif [ -n "$direct_rule" ]; then
        # full_tunnel: ONLY the explicit direct whitelist bypasses the VPN.
        rules="$rules,$(echo "$direct_rule" | jq '. + {outbound:"direct"}')"
    fi
    rules="$rules]"

    # DNS rules: VPN domains → dns-proxy FIRST, then RU → dns-direct
    dns_rules="["

    # Force-VPN domains must resolve through VPN DNS (before geosite-ru)
    if [ -n "$vpn_rule" ]; then
        local dns_vpn
        dns_vpn=$(echo "$vpn_rule" | jq '{}
            + (if .domain then {domain: .domain} else {} end)
            + (if .domain_suffix then {domain_suffix: .domain_suffix} else {} end)
            + {action: "route", server: "dns-proxy"}')
        dns_rules="$dns_rules$dns_vpn,"
    fi

    if [ "$full_tunnel" = "true" ]; then
        # Full-tunnel: everything resolves via dns-proxy (final) EXCEPT the
        # explicit direct whitelist, which resolves via dns-direct (Yandex) so it
        # gets RU-locality CDN IPs for streaming. The dangling "$dns_vpn," comma
        # (if any) is consumed by appending dns_cd; with no force-VPN rule the "["
        # absorbs it cleanly. No whitelist → strip the trailing comma and close.
        if [ -n "$direct_rule" ]; then
            local dns_cd
            dns_cd=$(echo "$direct_rule" | jq '{}
                + (if .domain then {domain: .domain} else {} end)
                + (if .domain_suffix then {domain_suffix: .domain_suffix} else {} end)
                + {action: "route", server: "dns-direct"}')
            dns_rules="$dns_rules$dns_cd]"
        else
            dns_rules="${dns_rules%,}]"
        fi
    else
        dns_rules="$dns_rules{\"rule_set\":[\"geosite-ru\"],\"action\":\"route\",\"server\":\"dns-direct\"}"
        if [ -n "$ru_rule" ]; then
            local dns_ru
            dns_ru=$(echo "$ru_rule" | jq '{}
                + (if .domain then {domain: .domain} else {} end)
                + (if .domain_suffix then {domain_suffix: .domain_suffix} else {} end)
                + (if .domain_keyword then {domain_keyword: .domain_keyword} else {} end)
                + {action: "route", server: "dns-direct"}')
            dns_rules="$dns_rules,$dns_ru"
        fi
        dns_rules="$dns_rules]"
    fi
}

_build_blocklist_rules() {
    # Mode: only blocked domains through VPN

    local domains_rule="" telegram_rule="" discord_rule="" meta_ips_rule="" telegram_ips_rule=""
    [ -f "$SR_RULES_DIR/domains.list" ] && domains_rule=$(convert_sr_to_singbox_rule "$SR_RULES_DIR/domains.list")
    [ -f "$SR_RULES_DIR/telegram.list" ] && telegram_rule=$(convert_sr_to_singbox_rule "$SR_RULES_DIR/telegram.list")
    [ -f "$SR_RULES_DIR/discord.list" ] && discord_rule=$(convert_sr_to_singbox_rule "$SR_RULES_DIR/discord.list")
    [ -f "$SR_RULES_DIR/meta_ips.list" ] && meta_ips_rule=$(convert_ip_list "$SR_RULES_DIR/meta_ips.list")
    [ -f "$SR_RULES_DIR/telegram_ips.list" ] && telegram_ips_rule=$(convert_ip_list "$SR_RULES_DIR/telegram_ips.list")

    # Force-VPN domains: built-in AI list ("Принудительно через VPN" tab in
    # the UI) merged with user's custom_vpn additions. _fetch_vpn_domains
    # writes both to vpn_domains.list. In blocklist mode this is critical
    # because the curated blocklist source misses Gemini/Perplexity/HF.
    # Funneled through jq for proper JSON escaping (defends against bad
    # chars in custom_vpn domains).
    local custom_vpn_rule=""
    if [ -f "$SR_RULES_DIR/vpn_domains.list" ]; then
        custom_vpn_rule=$(tr -d '\r' < "$SR_RULES_DIR/vpn_domains.list" \
            | grep -vE '^(#|$)' \
            | jq -R -s '[split("\n")[] | select(length > 0)]
                        | if length == 0 then null else {domain_suffix: .} end')
        [ "$custom_vpn_rule" = "null" ] && custom_vpn_rule=""
    fi

    rules="[{\"action\":\"sniff\",\"timeout\":\"300ms\"}"
    rules="$rules,{\"type\":\"logical\",\"mode\":\"or\",\"rules\":[{\"protocol\":\"dns\"},{\"port\":[53]}],\"action\":\"hijack-dns\"}"
    rules="$rules,{\"port\":[853],\"action\":\"reject\"}"
    rules="$rules,{\"network\":[\"udp\"],\"port\":[443],\"action\":\"reject\"}"

    for rule in "$custom_vpn_rule" "$domains_rule" "$telegram_rule" "$discord_rule" "$meta_ips_rule" "$telegram_ips_rule"; do
        [ -z "$rule" ] && continue
        rules="$rules,$(echo "$rule" | jq '. + {outbound:"default"}')"
    done
    rules="$rules]"

    # DNS rules: blocked + custom_vpn domains → dns-proxy (resolve through VPN)
    dns_rules="["
    local first="1"
    for rule in "$custom_vpn_rule" "$domains_rule" "$telegram_rule" "$discord_rule"; do
        [ -z "$rule" ] && continue
        local dns_rule
        dns_rule=$(echo "$rule" | jq '{}
            + (if .domain then {domain: .domain} else {} end)
            + (if .domain_suffix then {domain_suffix: .domain_suffix} else {} end)
            + (if .domain_keyword then {domain_keyword: .domain_keyword} else {} end)
            + {action: "route", server: "dns-proxy"}')
        # Skip a rule that carries no domain condition — it would route ALL DNS
        # to dns-proxy. The old string compare against a compact literal never
        # matched jq's pretty-printed output, so the guard was dead; check for
        # an actual domain key instead.
        echo "$dns_rule" | jq -e 'has("domain") or has("domain_suffix") or has("domain_keyword")' >/dev/null 2>&1 || continue
        [ "$first" = "1" ] || dns_rules="$dns_rules,"
        dns_rules="$dns_rules$dns_rule"
        first=""
    done
    dns_rules="$dns_rules]"
}

# ============================================================
# sing-box process management
# ============================================================

start_singbox() {
    local config_file="$1"
    if [ ! -x /usr/bin/sing-box ]; then
        logger -t eclipvpn "ERROR: /usr/bin/sing-box not found or not executable"
        return 1
    fi
    # Clear only the per-connection-ID map: sing-box assigns fresh IDs on each
    # boot, so old entries are dead weight. But keep the cumulative vpn_dl/ul
    # and dir_dl/ul totals — otherwise every restart (auto-update, set-server,
    # watchdog failover) wipes the user's running counter. Totals survive
    # tmpfs rebuilds only across restarts of sing-box, not router reboots.
    local _ts=/tmp/eclipvpn/traffic_state.json
    if [ -f "$_ts" ]; then
        jq '.seen = {}' "$_ts" > "$_ts.tmp" 2>/dev/null && mv "$_ts.tmp" "$_ts" || rm -f "$_ts" "$_ts.tmp"
    fi
    # Append-mode (>>) is critical: rotation truncates the file, but daemon's
    # write position keeps moving forward. Without O_APPEND, post-rotate writes
    # land at the old offset and the kernel fills the gap with NUL bytes —
    # the log balloons to tens of MB while only a few KB are real data.
    TZ=$(cat /etc/TZ 2>/dev/null || echo "MSK-3") /usr/bin/sing-box run -c "$config_file" -D /tmp/eclipvpn >>/tmp/eclipvpn/singbox.log 2>>/tmp/eclipvpn/singbox.log &
    echo $! > /tmp/eclipvpn/singbox.pid
    # Busy-poll (netstat-paced, ~20-40ms/iter) instead of a flat `sleep 1` loop:
    # busybox has no sub-second sleep, and sing-box binds :2154 in well under a
    # second (~0.3s measured) — the old 1s granularity DOMINATED the switch gap.
    # The netstat call itself paces the loop; the ~300-iter cap bounds it to
    # roughly the old 10s budget for a genuinely slow start.
    local tries=0
    while [ "$tries" -lt 300 ]; do
        kill -0 "$(cat /tmp/eclipvpn/singbox.pid)" 2>/dev/null || { rm -f /tmp/eclipvpn/singbox.pid; return 1; }
        netstat -tlnp 2>/dev/null | grep -q ":2154 " && return 0
        tries=$((tries + 1))
    done
    # Process alive but tproxy port never bound. Caller (cmd_start) would
    # otherwise apply nftables rules redirecting LAN traffic to an unbound
    # port — total internet outage on the LAN until manual intervention.
    logger -t eclipvpn "ERROR: sing-box started but tproxy port :2154 never opened"
    return 1
}

stop_singbox() {
    local pid=""
    [ -f /tmp/eclipvpn/singbox.pid ] && pid=$(cat /tmp/eclipvpn/singbox.pid)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    # Wait (netstat-paced, no flat `sleep 1`) for sing-box to exit and release
    # :2154 so the next start can bind it — sing-box dies in <0.5s, so a fixed 1s
    # sleep was pure switch-gap latency. Cap ~80 iters (~2-3s) before SIGKILL.
    local _i=0
    while netstat -tlnp 2>/dev/null | grep -q ":2154 "; do
        kill -0 "$pid" 2>/dev/null || break
        _i=$((_i + 1)); [ "$_i" -ge 80 ] && break
    done
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    # Same orphan-sweep as stop_xray — see comment there.
    for orphan in $(pgrep -f 'sing-box run -c /tmp/eclipvpn/singbox.json' 2>/dev/null); do
        [ "$orphan" = "$pid" ] && continue
        kill -9 "$orphan" 2>/dev/null
    done
    rm -f /tmp/eclipvpn/singbox.pid
}

is_singbox_running() {
    if [ -f /tmp/eclipvpn/singbox.pid ]; then
        local pid=$(cat /tmp/eclipvpn/singbox.pid 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    pgrep -f 'sing-box run -c /tmp/eclipvpn/singbox.json' >/dev/null 2>&1
}
