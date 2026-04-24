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

_fetch_blocklist_domains() {
    curl -s --max-time 15 -o "$SR_RULES_DIR/domains.list" \
        "https://raw.githubusercontent.com/misha-tgshv/shadowrocket-configuration-file/main/rules/domains_community.list"
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
    local file="$1"
    local domain_suffixes="" domain_keywords="" domains="" ip_cidrs=""

    while IFS= read -r line; do
        case "$line" in "#"*|"") continue ;; esac
        local type="${line%%,*}"
        local rest="${line#*,}"
        local value="${rest%%,*}"
        case "$type" in
            DOMAIN-SUFFIX) [ -n "$domain_suffixes" ] && domain_suffixes="$domain_suffixes,"; domain_suffixes="$domain_suffixes\"$value\"" ;;
            DOMAIN-KEYWORD) [ -n "$domain_keywords" ] && domain_keywords="$domain_keywords,"; domain_keywords="$domain_keywords\"$value\"" ;;
            DOMAIN) [ -n "$domains" ] && domains="$domains,"; domains="$domains\"$value\"" ;;
            IP-CIDR|IP-CIDR6) [ -n "$ip_cidrs" ] && ip_cidrs="$ip_cidrs,"; ip_cidrs="$ip_cidrs\"$value\"" ;;
        esac
    done < "$file"

    local rule="{" has_field=""
    if [ -n "$domain_suffixes" ]; then rule="$rule\"domain_suffix\":[$domain_suffixes]"; has_field="1"; fi
    if [ -n "$domain_keywords" ]; then [ -n "$has_field" ] && rule="$rule,"; rule="$rule\"domain_keyword\":[$domain_keywords]"; has_field="1"; fi
    if [ -n "$domains" ]; then [ -n "$has_field" ] && rule="$rule,"; rule="$rule\"domain\":[$domains]"; has_field="1"; fi
    if [ -n "$ip_cidrs" ]; then [ -n "$has_field" ] && rule="$rule,"; rule="$rule\"ip_cidr\":[$ip_cidrs]"; has_field="1"; fi
    rule="$rule}"
    [ -n "$has_field" ] && echo "$rule"
}

convert_ip_list() {
    local file="$1"
    local ip_cidrs=""
    while IFS= read -r line; do
        case "$line" in "#"*|"") continue ;; esac
        local ip="${line#IP-CIDR,}"; ip="${ip%%,*}"
        case "$ip" in [0-9]*) ;; *) continue ;; esac
        [ -n "$ip_cidrs" ] && ip_cidrs="$ip_cidrs,"
        ip_cidrs="$ip_cidrs\"$ip\""
    done < "$file"
    [ -n "$ip_cidrs" ] && echo "{\"ip_cidr\":[$ip_cidrs]}"
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

    # Build full config
    jq -n \
        --argjson rules "$rules" \
        --argjson dns_rules "$dns_rules" \
        --argjson xray_port "$xray_socks_port" \
        --arg final_outbound "$([ "$mode" = "all_vpn" ] && echo "default" || echo "direct")" \
        --arg final_dns "$([ "$mode" = "all_vpn" ] && echo "dns-proxy" || echo "dns-direct")" \
    '{
        log: {level: "info", timestamp: true},
        experimental: {
            cache_file: {enabled: true, path: "/tmp/flowvpn/cache.db"},
            clash_api: {external_controller: "0.0.0.0:9090", secret: "flowvpn"}
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
}

_build_allvpn_rules() {
    # Mode: everything through VPN, RU domains direct

    local ru_rule=""
    [ -f "$SR_RULES_DIR/ru_domains.list" ] && ru_rule=$(convert_sr_to_singbox_rule "$SR_RULES_DIR/ru_domains.list")

    # Custom VPN domains (force through VPN even if in RU list)
    local vpn_rule=""
    if [ -f "$CUSTOM_VPN" ]; then
        local vpn_suffixes=""
        while IFS= read -r line; do
            case "$line" in "#"*|"") continue ;; esac
            [ -n "$vpn_suffixes" ] && vpn_suffixes="$vpn_suffixes,"
            vpn_suffixes="$vpn_suffixes\"$line\""
        done < "$CUSTOM_VPN"
        [ -n "$vpn_suffixes" ] && vpn_rule="{\"domain_suffix\":[$vpn_suffixes]}"
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

    rules="[{\"action\":\"sniff\",\"timeout\":\"300ms\"}"
    rules="$rules,{\"type\":\"logical\",\"mode\":\"or\",\"rules\":[{\"protocol\":\"dns\"},{\"port\":[53]}],\"action\":\"hijack-dns\"}"
    rules="$rules,{\"port\":[853],\"action\":\"reject\"}"
    rules="$rules,{\"network\":[\"udp\"],\"port\":[443],\"action\":\"reject\"}"

    for rule in "$domains_rule" "$telegram_rule" "$discord_rule" "$meta_ips_rule" "$telegram_ips_rule"; do
        [ -z "$rule" ] && continue
        rules="$rules,$(echo "$rule" | jq '. + {outbound:"default"}')"
    done
    rules="$rules]"

    # DNS rules: blocked domains → dns-proxy
    dns_rules="["
    local first="1"
    for rule in "$domains_rule" "$telegram_rule" "$discord_rule"; do
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
    TZ=$(cat /etc/TZ 2>/dev/null || echo "MSK-3") /usr/bin/sing-box run -c "$config_file" -D /tmp/flowvpn >/tmp/flowvpn/singbox.log 2>&1 &
    echo $! > /tmp/flowvpn/singbox.pid
    local tries=0
    while [ "$tries" -lt 10 ]; do
        sleep 1; tries=$((tries + 1))
        kill -0 "$(cat /tmp/flowvpn/singbox.pid)" 2>/dev/null || { rm -f /tmp/flowvpn/singbox.pid; return 1; }
        netstat -tlnp 2>/dev/null | grep -q ":2154" && return 0
    done
    kill -0 "$(cat /tmp/flowvpn/singbox.pid)" 2>/dev/null
}

stop_singbox() {
    [ -f /tmp/flowvpn/singbox.pid ] || return 0
    local pid=$(cat /tmp/flowvpn/singbox.pid)
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
    rm -f /tmp/flowvpn/singbox.pid
}

is_singbox_running() {
    [ -f /tmp/flowvpn/singbox.pid ] && kill -0 "$(cat /tmp/flowvpn/singbox.pid)" 2>/dev/null
}
