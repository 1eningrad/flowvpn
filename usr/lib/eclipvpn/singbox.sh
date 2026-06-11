#!/bin/ash
# EclipVPN v3 — sing-box config generator
# Mode "all_vpn": everything through VPN, RU domains direct
# Mode "blocklist": only blocked domains through VPN (Shadowrocket lists)

SR_RULES_DIR="/tmp/eclipvpn/rules"
RULESET_DIR="/etc/eclipvpn/rules"
CUSTOM_DIRECT="/etc/eclipvpn/direct_domains.txt"
CUSTOM_VPN="/etc/eclipvpn/vpn_domains.txt"

GEOSITE_RU_URL="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs"
GEOIP_RU_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geoip/ru.srs"

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
    # Sing-box .srs rule sets: ensure cache exists, but do NOT force-refresh
    # here. fetch_rules is also called by cmd_start when /tmp is wiped (cold
    # boot), and force-refreshing across raw.githubusercontent.com (which
    # times out half the time from RU networks) added 60-90s to start time.
    # cmd_update calls _fetch_rule_sets force itself for the periodic refresh.
    _fetch_rule_sets
}

# Refresh the rule lists for $1=mode WITHOUT destroying the current ones
# first. cmd_update used to `rm -rf rules` and refetch — an offline run (or
# blocked GitHub) then left blocklist mode with an empty domains.list and the
# next restart silently sent everything direct. Fetch into a sidecar dir,
# sanity-check, swap; on a bad fetch the live lists stay untouched.
refresh_rules() {
    local mode="$1"
    local live_dir="$SR_RULES_DIR"
    local new_dir="${live_dir}.new"
    rm -rf "$new_dir"
    # fetch_rules and its helpers write to $SR_RULES_DIR — redirect them to
    # the sidecar via ash dynamic scoping (a `local` shadows the global for
    # every function called from here).
    local SR_RULES_DIR="$new_dir"
    fetch_rules "$mode"
    SR_RULES_DIR="$live_dir"
    # Sanity gate: heredoc-built lists always materialize; only the
    # downloaded blocklist can come back empty. Threshold matches the
    # "check network" warning in _fetch_blocklist_domains.
    if [ "$mode" != "all_vpn" ]; then
        local cnt
        cnt=$(wc -l < "$new_dir/domains.list" 2>/dev/null)
        if [ -z "$cnt" ] || [ "$cnt" -lt 50 ]; then
            flog "WARN: blocklist refetch failed/empty — keeping previous rule lists"
            rm -rf "$new_dir"
            return 1
        fi
    fi
    # Optional supplements: if the new fetch missed one the previous run
    # had (their curls are -f and can individually fail), carry it forward.
    local f
    for f in telegram.list discord.list meta_ips.list telegram_ips.list; do
        [ -s "$new_dir/$f" ] || { [ -s "$live_dir/$f" ] && cp "$live_dir/$f" "$new_dir/$f"; }
    done
    rm -rf "$live_dir"
    mv "$new_dir" "$live_dir"
}

# Persist sing-box .srs rule sets to /etc/eclipvpn/rules/ so sing-box loads
# them as type=local and never blocks startup on raw.githubusercontent.com.
# That host is reachable from RU only sporadically (~50% per attempt against
# round-robin IPs), and sing-box's startup fetch hits a hard timeout long
# before retries would bail it out — leading to "tproxy port :2154 never
# opened" failures on fresh installs.
#
# $1 = "force" → re-download even if a cached copy exists.
_fetch_rule_sets() {
    local force="${1:-}"
    mkdir -p "$RULESET_DIR"
    _fetch_one_srs "$RULESET_DIR/geosite-category-ru.srs" "$GEOSITE_RU_URL" "$force" || return 1
    _fetch_one_srs "$RULESET_DIR/ru.srs"                  "$GEOIP_RU_URL"   "$force" || return 1
}

_fetch_one_srs() {
    local dest="$1" url="$2" force="$3"
    # Existing non-trivial cache wins unless caller forces refresh.
    if [ -z "$force" ] && [ -s "$dest" ] && [ "$(wc -c < "$dest")" -gt 1024 ]; then
        return 0
    fi
    local tmp="${dest}.tmp.$$"
    # Bounded cold-boot budget: 3 tries x ~11s = ~33s/file (~66s for both),
    # down from 5x22s. This runs synchronously inside generate_singbox_config
    # before sing-box launches, so a long retry loop looks like a hang during
    # cmd_start and can blow past init.d/watchdog expectations.
    local i=0
    while [ "$i" -lt 3 ]; do
        # Validate it's actually a sing-box rule-set, not a 200-status
        # interception/CAPTCHA page >1KB: every .srs starts with the magic
        # bytes "SRS" (0x53 0x52 0x53). Without this a garbage page gets mv'd
        # into the PERSISTENT /etc cache, the cache-wins check then pins it,
        # and sing-box fails rule-set load on every start until manual deletion.
        if curl -fsSL --max-time 10 -o "$tmp" "$url" 2>/dev/null \
           && [ -s "$tmp" ] && [ "$(wc -c < "$tmp")" -gt 1024 ] \
           && [ "$(dd if="$tmp" bs=1 count=3 2>/dev/null)" = "SRS" ]; then
            mv "$tmp" "$dest"
            return 0
        fi
        rm -f "$tmp"
        i=$((i + 1))
        sleep 1
    done
    flog "ERROR: failed to fetch $(basename "$dest") from $url after 3 attempts"
    return 1
}

# Guarantee both local rule_set files exist so sing-box can load its config.
# On a fresh install where the fetch failed AND there is no cache (raw.gh
# blocked from inside RU), compile a valid EMPTY .srs via sing-box itself
# rather than letting startup fail with a missing rule_set path.
_ensure_srs_present() {
    local f
    for f in geosite-category-ru ru; do
        [ -s "$RULESET_DIR/$f.srs" ] && continue
        if _make_empty_srs "$RULESET_DIR/$f.srs"; then
            flog "WARN: $f.srs missing — using empty fallback (RU routing via manual list until next update)"
        else
            flog "ERROR: could not create fallback $f.srs — sing-box may refuse to start"
        fi
    done
}
_make_empty_srs() {
    # Compile to a temp then atomic-mv: a crash mid-compile must not leave a
    # partial .srs at the final path that the [ -s ] checks would accept.
    local dest="$1" src="${1}.src.json" tmp="${1}.tmp.$$"
    printf '%s' '{"version":1,"rules":[]}' > "$src"
    /usr/bin/sing-box rule-set compile --output "$tmp" "$src" 2>/dev/null
    local rc=$?
    rm -f "$src"
    if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
        mv "$tmp" "$dest"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Validate $1 as an IPv4 address or IPv4/CIDR (octets 0-255, prefix 0-32).
# Used to gate emission of IP-CIDR rules — an invalid one makes sing-box
# refuse the whole config (LAN-wide fail-closed outage), and the custom-direct
# list is reachable from any LAN client via the unauthenticated add-domain CGI.
_is_ipv4_cidr() {
    local ip="$1" pfx=""
    case "$ip" in
        */*) pfx="${ip##*/}"; ip="${ip%%/*}"
             case "$pfx" in ''|*[!0-9]*) return 1 ;; esac
             { [ "$pfx" -ge 0 ] && [ "$pfx" -le 32 ]; } 2>/dev/null || return 1 ;;
    esac
    case "$ip" in *[!0-9.]*|*..*|.*|*.) return 1 ;; esac
    local IFS=. o n=0
    for o in $ip; do
        case "$o" in ''|*[!0-9]*) return 1 ;; esac
        [ "$o" -le 255 ] 2>/dev/null || return 1
        n=$((n + 1))
    done
    [ "$n" -eq 4 ]
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
DOMAIN-SUFFIX,trbcdn.net
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

    # Add custom direct entries from user config. Lines that look like IPv4
    # (with optional /CIDR) become IP-CIDR rules; everything else is treated
    # as a domain suffix. Sniffing only catches TLS SNI, so apps that hit
    # an IP directly (cached A record, hardcoded host) need an IP-based rule
    # to bypass VPN.
    if [ -f "$CUSTOM_DIRECT" ]; then
        # tr -d '\r': a CRLF custom file (scp'd from Windows) would otherwise
        # bake "domain\r" suffixes that silently never match.
        tr -d '\r' < "$CUSTOM_DIRECT" | while IFS= read -r line; do
            case "$line" in "#"*|"") continue ;; esac
            case "$line" in
                [0-9]*.[0-9]*.[0-9]*.[0-9]*)
                    if _is_ipv4_cidr "$line"; then
                        echo "IP-CIDR,$line"
                    else
                        # Looked like an IP but isn't valid. A slash means it was
                        # meant as a CIDR (e.g. 10.0.0.1/99) → drop it rather than
                        # feed sing-box a config it will reject. No slash means it's
                        # a domain that happens to start with digit labels
                        # (1.2.3.4.example.com) → keep as a domain suffix.
                        case "$line" in
                            */*) flog "WARN: skipping invalid CIDR direct entry: $line" ;;
                            *)   echo "DOMAIN-SUFFIX,$line" ;;
                        esac
                    fi ;;
                *)
                    echo "DOMAIN-SUFFIX,$line" ;;
            esac
        done >> "$SR_RULES_DIR/ru_domains.list"
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

    # Append domains from any enabled service presets. Read once from
    # config to avoid jq-per-name; loop in shell. Unknown names from
    # config (e.g. an old preset removed in code) silently skip — the
    # _preset_domains helper returns 1 with no output.
    local enabled
    enabled=$(jq -r '.enabled_presets // [] | .[]' "$ECLIPVPN_CONFIG" 2>/dev/null)
    for p in $enabled; do
        # Capture in a var instead of a predictable /tmp/.preset.$$ temp file
        # (world-readable path outside our /tmp/eclipvpn namespace).
        local _pd
        _pd=$(_preset_domains "$p" 2>/dev/null) && [ -n "$_pd" ] && {
            echo "# preset: $p"
            printf '%s\n' "$_pd"
        }
    done >> "$SR_RULES_DIR/vpn_domains.list"

    # Append user's custom VPN-forced domains (one per line, comments stripped).
    # tr -d '\r' guards against CRLF custom files (Windows scp).
    if [ -f "$CUSTOM_VPN" ]; then
        tr -d '\r' < "$CUSTOM_VPN" | while IFS= read -r line; do
            case "$line" in "#"*|"") continue ;; esac
            echo "$line"
        done >> "$SR_RULES_DIR/vpn_domains.list"
    fi
}

# Service-preset domain lists. UI shows these as one-click toggles. Names
# referenced from cmd_preset and the UI must match these cases. Inline
# (not separate files) so the script remains a single deployment unit.
_preset_domains() {
    case "$1" in
        youtube) cat <<'EOF'
youtube.com
youtu.be
youtube-nocookie.com
ytimg.com
googlevideo.com
withyoutube.com
youtubekids.com
EOF
            ;;
        spotify) cat <<'EOF'
spotify.com
scdn.co
spotifycdn.com
spotify-everywhere.com
EOF
            ;;
        twitter) cat <<'EOF'
twitter.com
x.com
twimg.com
t.co
twttr.com
tweetdeck.com
EOF
            ;;
        instagram) cat <<'EOF'
instagram.com
cdninstagram.com
instagramcdn.com
EOF
            ;;
        facebook) cat <<'EOF'
facebook.com
fb.com
fbcdn.net
fbsbx.com
messenger.com
EOF
            ;;
        tiktok) cat <<'EOF'
tiktok.com
tiktokcdn.com
tiktokv.com
musical.ly
byteoversea.com
ibytedtos.com
EOF
            ;;
        reddit) cat <<'EOF'
reddit.com
redd.it
redditmedia.com
redditstatic.com
EOF
            ;;
        *) return 1 ;;
    esac
}

# Authoritative preset name list. Order = display order in UI.
_preset_names() {
    echo "youtube spotify twitter instagram facebook tiktok reddit"
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
    # Fetch-then-swap. A failed/blocked fetch must NOT clobber a good live
    # domains.list with an empty file: `> file` always creates it, and the
    # cold-boot gate in cmd_start tests `-f` (not `-s`), so a 0-line file gets
    # cached as a valid list and blocklist mode then runs rule-less (everything
    # direct) until the next successful update. Stage into .new, sanity-check
    # the line count, swap only on success. -fsS also drops HTTP error pages
    # (>50-line CAPTCHA/block pages would otherwise pass the count gate).
    local tmp_dl="$SR_RULES_DIR/domains.list.new"
    curl -fsS --max-time 30 "$url" 2>/dev/null | \
        awk 'NF && !/^#/ && !/^!/ {gsub(/[[:space:]]+/, "", $0); if(length($0)) print "DOMAIN-SUFFIX," $0}' \
        > "$tmp_dl"
    local cnt=$(wc -l < "$tmp_dl" 2>/dev/null)
    [ -z "$cnt" ] && cnt=0
    if [ "$cnt" -ge 50 ]; then
        mv "$tmp_dl" "$SR_RULES_DIR/domains.list"
    else
        rm -f "$tmp_dl"
        flog "WARNING: blocklist source $source returned only $cnt entries — keeping previous domains.list"
    fi

    # Telegram + Discord lists supplement domain-based routing for these
    # specific apps (their domain routing alone is unreliable due to
    # CDN sharding). Both are well-maintained.
    curl -fsSL --max-time 15 -o "$SR_RULES_DIR/telegram.list" \
        "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Shadowrocket/Telegram/Telegram.list"
    curl -fsSL --max-time 15 -o "$SR_RULES_DIR/discord.list" \
        "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Shadowrocket/Discord/Discord.list"
    # github.com/.../releases/latest/download/ ALWAYS 302-redirects to
    # objects.githubusercontent.com — WITHOUT -L curl writes the empty redirect
    # body, convert_ip_list emits nothing, and the Meta/Telegram IP-CIDR bypass
    # rules silently never load. -f also drops error pages instead of caching them.
    curl -fsSL --max-time 15 -o "$SR_RULES_DIR/meta_ips.list" \
        "https://github.com/toneywhitez/zkeen_rules/releases/latest/download/meta_ips.list"
    curl -fsSL --max-time 15 -o "$SR_RULES_DIR/telegram_ips.list" \
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

    # Sing-box reads geosite-ru/geoip-ru as local files (see rule_set block
    # below). They MUST exist or sing-box refuses to start. Cached files from a
    # prior run are reused; only the first install pays the curl-retry cost.
    # If the fetch fails and there's no cache, _ensure_srs_present compiles an
    # empty .srs so the VPN still comes up (degraded RU routing) instead of
    # failing to start entirely.
    _fetch_rule_sets || flog "WARN: rule-set fetch failed; relying on cache or empty fallback"
    _ensure_srs_present

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
        log: {level: "info", timestamp: true},
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
        vpn_rule=$(tr -d '\r' < "$SR_RULES_DIR/vpn_domains.list" | grep -vE '^(#|$)' \
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
    local tries=0
    while [ "$tries" -lt 10 ]; do
        sleep 1; tries=$((tries + 1))
        kill -0 "$(cat /tmp/eclipvpn/singbox.pid)" 2>/dev/null || { rm -f /tmp/eclipvpn/singbox.pid; return 1; }
        netstat -tlnp 2>/dev/null | grep -q ":2154 " && return 0
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
    sleep 1
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
