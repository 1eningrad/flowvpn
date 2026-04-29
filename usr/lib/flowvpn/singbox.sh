#!/bin/ash
# FlowVPN v3 — sing-box config generator
# Mode "all_vpn": everything through VPN, RU domains direct
# Mode "blocklist": only blocked domains through VPN (Shadowrocket lists)

SR_RULES_DIR="/tmp/flowvpn/rules"
CUSTOM_DIRECT="/etc/flowvpn/direct_domains.txt"
CUSTOM_VPN="/etc/flowvpn/vpn_domains.txt"

# ============================================================
# Download rule lists
# ============================================================

fetch_rules() {
    local mode="$1"
    mkdir -p "$SR_RULES_DIR"

    if [ "$mode" = "all_vpn" ]; then
        # RU domains — go DIRECT (everything else → VPN)
        _fetch_ru_domains
    else
        # Blocklist mode — blocked domains go through VPN
        _fetch_blocklist_domains
    fi
    # Force-VPN list (AI services blocked from RU IPs) is rebuilt for both
    # modes — the UI's vpn_domains.txt tab is exposed in either mode.
    _fetch_vpn_domains
}

_fetch_ru_domains() {
    # RU domains that should go DIRECT (bypass VPN)
    # Only actual Russian services, NOT blocked sites
    {
        echo "# RU domains — go DIRECT"
        # Russian services (manual list)
        cat << 'RUEOF'
DOMAIN-SUFFIX,yandex.ru
DOMAIN-SUFFIX,yandex.net
DOMAIN-SUFFIX,yandex.com
DOMAIN-SUFFIX,ya.ru
DOMAIN-SUFFIX,yastatic.net
DOMAIN-SUFFIX,yandex.st
DOMAIN-SUFFIX,mail.ru
DOMAIN-SUFFIX,list.ru
DOMAIN-SUFFIX,bk.ru
DOMAIN-SUFFIX,inbox.ru
DOMAIN-SUFFIX,vk.com
DOMAIN-SUFFIX,vk.me
DOMAIN-SUFFIX,vkontakte.ru
DOMAIN-SUFFIX,userapi.com
DOMAIN-SUFFIX,vk.cc
DOMAIN-SUFFIX,sber.ru
DOMAIN-SUFFIX,sberbank.ru
DOMAIN-SUFFIX,gosuslugi.ru
DOMAIN-SUFFIX,mos.ru
DOMAIN-SUFFIX,nalog.gov.ru
DOMAIN-SUFFIX,tinkoff.ru
DOMAIN-SUFFIX,tbank.ru
DOMAIN-SUFFIX,alfabank.ru
DOMAIN-SUFFIX,vtb.ru
DOMAIN-SUFFIX,ozon.ru
DOMAIN-SUFFIX,ozon.st
DOMAIN-SUFFIX,wildberries.ru
DOMAIN-SUFFIX,wbstatic.net
DOMAIN-SUFFIX,wb.ru
DOMAIN-SUFFIX,avito.ru
DOMAIN-SUFFIX,avito.st
DOMAIN-SUFFIX,kinopoisk.ru
DOMAIN-SUFFIX,rutube.ru
DOMAIN-SUFFIX,ok.ru
DOMAIN-SUFFIX,mts.ru
DOMAIN-SUFFIX,megafon.ru
DOMAIN-SUFFIX,beeline.ru
DOMAIN-SUFFIX,tele2.ru
DOMAIN-SUFFIX,ivi.ru
DOMAIN-SUFFIX,2gis.ru
DOMAIN-SUFFIX,2gis.com
DOMAIN-SUFFIX,drom.ru
DOMAIN-SUFFIX,auto.ru
DOMAIN-SUFFIX,dns-shop.ru
DOMAIN-SUFFIX,mvideo.ru
DOMAIN-SUFFIX,citilink.ru
DOMAIN-SUFFIX,eldorado.ru
DOMAIN-SUFFIX,lamoda.ru
DOMAIN-SUFFIX,hh.ru
DOMAIN-SUFFIX,ria.ru
DOMAIN-SUFFIX,rbc.ru
DOMAIN-SUFFIX,lenta.ru
DOMAIN-SUFFIX,kommersant.ru
DOMAIN-SUFFIX,tass.ru
DOMAIN-SUFFIX,gazeta.ru
DOMAIN-SUFFIX,kp.ru
DOMAIN-SUFFIX,rt.com
DOMAIN-SUFFIX,cdek.ru
DOMAIN-SUFFIX,pochta.ru
DOMAIN-SUFFIX,rzd.ru
DOMAIN-SUFFIX,aeroflot.ru
DOMAIN-SUFFIX,s7.ru
DOMAIN-SUFFIX,pikabu.ru
DOMAIN-SUFFIX,habr.com
DOMAIN-SUFFIX,2ip.ru
DOMAIN-SUFFIX,samokat.ru
DOMAIN-SUFFIX,sportmaster.ru
DOMAIN-SUFFIX,detmir.ru
DOMAIN-SUFFIX,leroymerlin.ru
DOMAIN-SUFFIX,perekrestok.ru
DOMAIN-SUFFIX,magnit.ru
DOMAIN-SUFFIX,sbermegamarket.ru
DOMAIN-SUFFIX,vkusvill.ru
DOMAIN-SUFFIX,1c.ru
# Banks (extras)
DOMAIN-SUFFIX,raiffeisen.ru
DOMAIN-SUFFIX,gazprombank.ru
DOMAIN-SUFFIX,otkritie.ru
DOMAIN-SUFFIX,psbank.ru
DOMAIN-SUFFIX,rshb.ru
DOMAIN-SUFFIX,sovcombank.ru
DOMAIN-SUFFIX,rosbank.ru
DOMAIN-SUFFIX,mkb.ru
DOMAIN-SUFFIX,yoomoney.ru
DOMAIN-SUFFIX,yookassa.ru
DOMAIN-SUFFIX,nspk.ru
DOMAIN-SUFFIX,mironline.ru
# Sber ecosystem
DOMAIN-SUFFIX,sber.com
DOMAIN-SUFFIX,sbermarket.ru
DOMAIN-SUFFIX,megamarket.ru
DOMAIN-SUFFIX,sberhealth.ru
DOMAIN-SUFFIX,sberdevices.ru
# Telcos / streaming bundles
DOMAIN-SUFFIX,mts-link.ru
DOMAIN-SUFFIX,kion.ru
DOMAIN-SUFFIX,premier.one
DOMAIN-SUFFIX,yota.ru
DOMAIN-SUFFIX,rt.ru
DOMAIN-SUFFIX,wink.ru
# Gov / state
DOMAIN-SUFFIX,nalog.ru
DOMAIN-SUFFIX,pfr.gov.ru
DOMAIN-SUFFIX,sfr.gov.ru
DOMAIN-SUFFIX,mvd.ru
DOMAIN-SUFFIX,rosreestr.ru
DOMAIN-SUFFIX,emias.info
DOMAIN-SUFFIX,mosreg.ru
# Marketplaces / delivery
DOMAIN-SUFFIX,aliexpress.ru
DOMAIN-SUFFIX,joom.ru
DOMAIN-SUFFIX,delivery-club.ru
DOMAIN-SUFFIX,dodopizza.ru
# Streaming / media
DOMAIN-SUFFIX,okko.tv
DOMAIN-SUFFIX,okko.ru
DOMAIN-SUFFIX,okko.com
DOMAIN-SUFFIX,okkoapi.tv
DOMAIN-SUFFIX,okko.sport
DOMAIN-SUFFIX,playfamily.ru
DOMAIN-SUFFIX,start.ru
DOMAIN-SUFFIX,more.tv
DOMAIN-SUFFIX,amediateka.ru
DOMAIN-SUFFIX,1tv.ru
DOMAIN-SUFFIX,channelone.ru
# News / aggregators
DOMAIN-SUFFIX,vc.ru
DOMAIN-SUFFIX,dtf.ru
DOMAIN-SUFFIX,afisha.ru
DOMAIN-SUFFIX,rambler.ru
# Jobs / education
DOMAIN-SUFFIX,skillbox.ru
DOMAIN-SUFFIX,superjob.ru
DOMAIN-SUFFIX,rabota.ru
# Reading / health
DOMAIN-SUFFIX,litres.ru
DOMAIN-SUFFIX,prodoctorov.ru
# Business tools
DOMAIN-SUFFIX,sbis.ru
DOMAIN-SUFFIX,dadata.ru
# Yandex group (extras from v2fly canon)
DOMAIN-SUFFIX,yango.com
DOMAIN-SUFFIX,yango.kz
DOMAIN-SUFFIX,naydex.net
DOMAIN-SUFFIX,adfox.ru
DOMAIN-SUFFIX,clck.ru
# VK / Mail.ru group (extras)
DOMAIN-SUFFIX,vk.ru
DOMAIN-SUFFIX,my.com
DOMAIN-SUFFIX,apiok.ru
DOMAIN-SUFFIX,vkplay.ru
DOMAIN-SUFFIX,vkplay.live
DOMAIN-SUFFIX,rustore.ru
# Ozon geo + ecosystem
DOMAIN-SUFFIX,ozon.com
DOMAIN-SUFFIX,ozon.kz
DOMAIN-SUFFIX,ozon.by
DOMAIN-SUFFIX,ozon.tech
DOMAIN-SUFFIX,o3.ru
# 2GIS geo
DOMAIN-SUFFIX,2gis.kz
DOMAIN-SUFFIX,2gis.by
DOMAIN-SUFFIX,2gis.uz
DOMAIN-SUFFIX,2gis.kg
DOMAIN-SUFFIX,2gis.ae
# HeadHunter geo
DOMAIN-SUFFIX,hh.by
DOMAIN-SUFFIX,hh.kz
DOMAIN-SUFFIX,hhcdn.ru
DOMAIN-SUFFIX,zarplata.ru
DOMAIN-SUFFIX,talantix.ru
# Antivirus / IT services
DOMAIN-SUFFIX,kaspersky.ru
DOMAIN-SUFFIX,kaspersky.com
DOMAIN-SUFFIX,kontur.ru
# Hosting / cloud
DOMAIN-SUFFIX,selectel.ru
DOMAIN-SUFFIX,selcdn.net
DOMAIN-SUFFIX,timeweb.com
DOMAIN-SUFFIX,timeweb.cloud
DOMAIN-SUFFIX,beget.ru
DOMAIN-SUFFIX,beget.com
# Site builders / CMS
DOMAIN-SUFFIX,tilda.cc
DOMAIN-SUFFIX,tilda.ws
DOMAIN-SUFFIX,tildacdn.com
DOMAIN-SUFFIX,ucoz.ru
# Education / health / weather
DOMAIN-SUFFIX,gismeteo.ru
DOMAIN-SUFFIX,skyeng.ru
DOMAIN-SUFFIX,sky.pro
DOMAIN-SUFFIX,medsi.ru
DOMAIN-SUFFIX,mosgorzdrav.ru
# Travel / transport
DOMAIN-SUFFIX,aviasales.ru
DOMAIN-SUFFIX,aviasales.com
DOMAIN-SUFFIX,tutu.ru
DOMAIN-SUFFIX,ostrovok.ru
DOMAIN-SUFFIX,blablacar.ru
DOMAIN-SUFFIX,mosmetro.ru
DOMAIN-SUFFIX,whoosh.bike
# Retail (X5 + others)
DOMAIN-SUFFIX,x5.ru
DOMAIN-SUFFIX,5ka.ru
DOMAIN-SUFFIX,dixy.ru
DOMAIN-SUFFIX,auchan.ru
# Streaming extras
DOMAIN-SUFFIX,smotreshka.tv
DOMAIN-SUFFIX,viju.ru
DOMAIN-SUFFIX,kinorium.com
# Banks / finance (Central Bank + extras)
DOMAIN-SUFFIX,cbr.ru
DOMAIN-SUFFIX,ozonbank.ru
# CRM / marketing tools
DOMAIN-SUFFIX,mindbox.ru
DOMAIN-SUFFIX,mindbox.cloud
DOMAIN-SUFFIX,carrotquest.io
# Office
DOMAIN-SUFFIX,myoffice.ru
RUEOF
    } > "$SR_RULES_DIR/ru_domains.list"

    # Add custom direct domains from user config
    if [ -f "$CUSTOM_DIRECT" ]; then
        while IFS= read -r line; do
            case "$line" in "#"*|"") continue ;; esac
            echo "DOMAIN-SUFFIX,$line" >> "$SR_RULES_DIR/ru_domains.list"
        done < "$CUSTOM_DIRECT"
    fi
}

_fetch_vpn_domains() {
    # Force-VPN list — AI / chat services that 403 on Russian IPs.
    # Built into a single file so _build_*_rules can read one source instead
    # of merging heredoc + CUSTOM_VPN at every config rebuild.
    {
        cat << 'VPNEOF'
# OpenAI
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
# Anthropic
anthropic.com
claude.ai
# Google AI (specific subdomains — root google.com is in geosite-ru)
gemini.google.com
aistudio.google.com
ai.google.dev
notebooklm.google.com
bard.google.com
generativelanguage.googleapis.com
deepmind.com
# Hugging Face
huggingface.co
huggingface.com
# Chat / search AI
perplexity.ai
you.com
poe.com
pi.ai
character.ai
character.com
# Image / video gen
midjourney.com
stability.ai
replicate.com
runwayml.com
# Microsoft Copilot
copilot.microsoft.com
# Other LLM providers
mistral.ai
cohere.com
cohere.ai
meta.ai
VPNEOF
    } > "$SR_RULES_DIR/vpn_domains.list"

    # Append user's custom VPN-forced domains (one per line, comments stripped).
    if [ -f "$CUSTOM_VPN" ]; then
        while IFS= read -r line; do
            case "$line" in "#"*|"") continue ;; esac
            echo "$line" >> "$SR_RULES_DIR/vpn_domains.list"
        done < "$CUSTOM_VPN"
    fi
}

_fetch_blocklist_domains() {
    # Source choice: a curated "actually-needs-bypass" list works better for
    # Russia than dumping the full RKN registry — RKN includes lots of
    # domains (gambling, malware, phishing) that no one needs unblocked,
    # and a million-entry rule-set bogs down sing-box on an embedded router.
    #
    # Default = itdoginfo/allow-domains (~1.2k entries, hand-curated for
    # the services people actually want: YouTube, X, ChatGPT, Discord, etc.)
    # Fallback = 1andrevich/Re-filter-lists (~80k, more comprehensive but
    # still without registry junk) when blocklist_source=full.
    local source
    source=$(get_config_val blocklist_source "curated")
    local url
    case "$source" in
        full) url="https://raw.githubusercontent.com/1andrevich/Re-filter-lists/main/domains_all.lst" ;;
        *)    url="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst" ;;
    esac

    # These lists ship as plain domains, one per line (no DOMAIN-SUFFIX prefix
    # like Shadowrocket lists). Wrap each line in the SR format that
    # convert_sr_to_singbox_rule already understands.
    curl -s --max-time 30 "$url" | \
        awk 'NF && !/^#/ && !/^!/ {gsub(/[[:space:]]+/, "", $0); if(length($0)) print "DOMAIN-SUFFIX," $0}' \
        > "$SR_RULES_DIR/domains.list"

    local cnt=$(wc -l < "$SR_RULES_DIR/domains.list" 2>/dev/null)
    [ -z "$cnt" ] || [ "$cnt" -lt 50 ] && \
        flog "WARNING: blocklist source $source returned only $cnt entries — check network"

    # Telegram + Discord lists supplement domain-based routing for these
    # specific apps (their domain routing alone is unreliable due to
    # CDN sharding). Both are well-maintained.
    curl -s --max-time 15 -o "$SR_RULES_DIR/telegram.list" \
        "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Shadowrocket/Telegram/Telegram.list"
    curl -s --max-time 15 -o "$SR_RULES_DIR/discord.list" \
        "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Shadowrocket/Discord/Discord.list"
    curl -s --max-time 15 -o "$SR_RULES_DIR/meta_ips.list" \
        "https://github.com/toneywhitez/zkeen_rules/releases/latest/download/meta_ips.list"
    curl -s --max-time 15 -o "$SR_RULES_DIR/telegram_ips.list" \
        "https://github.com/toneywhitez/zkeen_rules/releases/latest/download/telegram_ips.list"
}

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
# Generate sing-box config
# ============================================================

generate_singbox_config() {
    local output="$1" xray_socks_port="$2" mode="$3"

    local rules dns_rules

    if [ "$mode" = "all_vpn" ]; then
        _build_allvpn_rules
    else
        _build_blocklist_rules
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
        --argjson xray_port "$xray_socks_port" \
        --arg clash_secret "$clash_secret" \
        --arg final_outbound "$([ "$mode" = "all_vpn" ] && echo "default" || echo "direct")" \
        --arg final_dns "$([ "$mode" = "all_vpn" ] && echo "dns-proxy" || echo "dns-direct")" \
    '{
        log: {level: "warn", timestamp: true},
        experimental: {
            cache_file: {enabled: true, path: "/tmp/flowvpn/cache.db"},
            clash_api: {external_controller: "0.0.0.0:9090", secret: $clash_secret}
        },
        dns: {
            servers: [
                {tag: "dns-proxy", type: "tls", server: "1.1.1.1", detour: "default"},
                {tag: "dns-direct", type: "udp", server: "1.1.1.1", detour: "direct"},
                {tag: "dns-block", type: "udp", server: "127.0.0.127"}
            ],
            rules: $dns_rules,
            final: $final_dns,
            strategy: "ipv4_only"
        },
        inbounds: [
            {type: "tproxy", tag: "tproxy-in", listen: "::", listen_port: 2154},
            {type: "direct", tag: "dns-in", listen: "127.0.0.1", listen_port: 5354}
        ],
        outbounds: [
            {type: "direct", tag: "direct", routing_mark: 32768},
            {type: "socks", tag: "default", server: "127.0.0.1", server_port: $xray_port, version: "5"}
        ],
        route: {
            default_domain_resolver: "dns-direct",
            default_mark: 32768,
            rules: $rules,
            rule_set: [
                {type: "remote", tag: "geosite-ru", format: "binary",
                 url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs",
                 download_detour: "direct"},
                {type: "remote", tag: "geoip-ru", format: "binary",
                 url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/ru.srs",
                 download_detour: "direct"}
            ],
            final: $final_outbound,
            auto_detect_interface: true
        }
    }' > "$output"
    # sing-box config holds the Clash API secret; tighten file mode.
    chmod 600 "$output" 2>/dev/null
}

_build_allvpn_rules() {
    # Mode: everything through VPN, RU domains direct

    local ru_rule=""
    [ -f "$SR_RULES_DIR/ru_domains.list" ] && ru_rule=$(convert_sr_to_singbox_rule "$SR_RULES_DIR/ru_domains.list")

    # Force-VPN domains (built-in AI services + user's custom_vpn).
    # _fetch_vpn_domains rebuilds vpn_domains.list on every fetch_rules and
    # on every add-domain/remove-domain. We funnel the file through jq so
    # any quote/backslash in a user-added domain becomes properly-escaped
    # JSON instead of breaking the rule string we hand to sing-box.
    local vpn_rule=""
    if [ -f "$SR_RULES_DIR/vpn_domains.list" ]; then
        vpn_rule=$(grep -vE '^(#|$)' "$SR_RULES_DIR/vpn_domains.list" \
            | jq -R -s '[split("\n")[] | select(length > 0)]
                        | if length == 0 then null else {domain_suffix: .} end')
        [ "$vpn_rule" = "null" ] && vpn_rule=""
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

    # RU traffic → direct (geosite + geoip + manual list)
    rules="$rules,{\"rule_set\":[\"geosite-ru\",\"geoip-ru\"],\"outbound\":\"direct\"}"
    if [ -n "$ru_rule" ]; then
        rules="$rules,$(echo "$ru_rule" | jq '. + {outbound:"direct"}')"
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
        [ "$dns_rule" = '{"action":"route","server":"dns-proxy"}' ] && continue
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
        logger -t flowvpn "ERROR: /usr/bin/sing-box not found or not executable"
        return 1
    fi
    # Clear only the per-connection-ID map: sing-box assigns fresh IDs on each
    # boot, so old entries are dead weight. But keep the cumulative vpn_dl/ul
    # and dir_dl/ul totals — otherwise every restart (auto-update, set-server,
    # watchdog failover) wipes the user's running counter. Totals survive
    # tmpfs rebuilds only across restarts of sing-box, not router reboots.
    local _ts=/tmp/flowvpn/traffic_state.json
    if [ -f "$_ts" ]; then
        jq '.seen = {}' "$_ts" > "$_ts.tmp" 2>/dev/null && mv "$_ts.tmp" "$_ts" || rm -f "$_ts" "$_ts.tmp"
    fi
    # Append-mode (>>) is critical: rotation truncates the file, but daemon's
    # write position keeps moving forward. Without O_APPEND, post-rotate writes
    # land at the old offset and the kernel fills the gap with NUL bytes —
    # the log balloons to tens of MB while only a few KB are real data.
    TZ=$(cat /etc/TZ 2>/dev/null || echo "MSK-3") /usr/bin/sing-box run -c "$config_file" -D /tmp/flowvpn >>/tmp/flowvpn/singbox.log 2>>/tmp/flowvpn/singbox.log &
    echo $! > /tmp/flowvpn/singbox.pid
    local tries=0
    while [ "$tries" -lt 10 ]; do
        sleep 1; tries=$((tries + 1))
        kill -0 "$(cat /tmp/flowvpn/singbox.pid)" 2>/dev/null || { rm -f /tmp/flowvpn/singbox.pid; return 1; }
        netstat -tlnp 2>/dev/null | grep -q ":2154" && return 0
    done
    # Process alive but tproxy port never bound. Caller (cmd_start) would
    # otherwise apply nftables rules redirecting LAN traffic to an unbound
    # port — total internet outage on the LAN until manual intervention.
    logger -t flowvpn "ERROR: sing-box started but tproxy port :2154 never opened"
    return 1
}

stop_singbox() {
    local pid=""
    [ -f /tmp/flowvpn/singbox.pid ] && pid=$(cat /tmp/flowvpn/singbox.pid)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    sleep 1
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
    # Same orphan-sweep as stop_xray — see comment there.
    for orphan in $(pgrep -f 'sing-box run -c /tmp/flowvpn/singbox.json' 2>/dev/null); do
        [ "$orphan" = "$pid" ] && continue
        kill -9 "$orphan" 2>/dev/null
    done
    rm -f /tmp/flowvpn/singbox.pid
}

is_singbox_running() {
    if [ -f /tmp/flowvpn/singbox.pid ]; then
        local pid=$(cat /tmp/flowvpn/singbox.pid 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    fi
    pgrep -f 'sing-box run -c /tmp/flowvpn/singbox.json' >/dev/null 2>&1
}
