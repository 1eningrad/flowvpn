#!/bin/ash
# EclipVPN — routing-rule & domain-list sourcing (split out of singbox.sh on
# 2026-06-16; was its top half). Fetches/compiles the sing-box .srs rule sets
# and builds the RU-direct, force-VPN, blocklist and service-preset domain
# lists. Sourced into /usr/bin/eclipvpn alongside singbox.sh; shares its
# globals (SR_RULES_DIR, RULESET_DIR, CUSTOM_DIRECT/CUSTOM_VPN, GEOSITE_RU_URL/
# GEOIP_RU_URL — still defined at the top of singbox.sh) and helpers, all
# resolved at call time, so source order among the libs does not matter.

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

# A freshly-FETCHED .srs is valid only if it's >1KB AND starts with the magic
# bytes "SRS" (0x53 0x52 0x53) — rejects a 200-status CAPTCHA/intercept page.
# NB: this is stricter than the cache-wins gate in _fetch_one_srs, which
# deliberately accepts the ~17-byte EMPTY fallback (magic bytes only, no size
# floor) so a degraded-but-valid cache still wins over a re-fetch.
_is_valid_srs() {
    [ -s "$1" ] && [ "$(wc -c < "$1")" -gt 1024 ] \
        && [ "$(dd if="$1" bs=1 count=3 2>/dev/null)" = "SRS" ]
}

_fetch_one_srs() {
    local dest="$1" url="$2" force="$3"
    # An existing VALID cache wins unless the caller forces a refresh. Gate on the
    # SRS magic bytes ("SRS" = 0x53 0x52 0x53), NOT size>1024: an _ensure_srs_present
    # empty fallback is a perfectly valid ~17-byte .srs, and the old size gate
    # rejected it — so on a network where raw.githubusercontent.com is blocked
    # (RU), EVERY restart/switch re-tried the fetch (3x~11s x2 files ≈ 60s),
    # which surfaced as "can't switch server" / hangs (2026-06-20). cmd_update
    # still passes force=1 to pull the real lists when the network allows.
    if [ -z "$force" ] && [ -s "$dest" ] && [ "$(dd if="$dest" bs=1 count=3 2>/dev/null)" = "SRS" ]; then
        return 0
    fi
    local tmp="${dest}.tmp.$$"
    # Bounded cold-boot budget: 3 tries. This runs synchronously inside
    # generate_singbox_config before sing-box launches, so a long retry loop looks
    # like a hang during cmd_start. Each try goes through _router_fetch (direct →
    # tunnel fallback, the shared primitive) — file-based, so .srs stays binary-
    # safe (a shell-var capture would corrupt it). _is_valid_srs (>1KB + "SRS"
    # magic) rejects a 200-status CAPTCHA/intercept page so garbage never gets
    # mv'd into the PERSISTENT /etc cache (which the cache-wins gate would pin).
    local i=0
    while [ "$i" -lt 3 ]; do
        if _router_fetch "$url" "$tmp" -L && _is_valid_srs "$tmp"; then
            mv "$tmp" "$dest"; return 0
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
# YouTube — heavily throttled on RU networks (per-flow policer), so force it
# through the VPN by default for every install. googlevideo.com is the video
# CDN, youtubei.googleapis.com the app/API endpoint. (There is also a
# toggleable `youtube` service preset; this built-in entry is the always-on
# baseline so a fresh install gets working YouTube out of the box.)
youtube.com
youtu.be
youtube-nocookie.com
ytimg.com
googlevideo.com
youtubei.googleapis.com
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

# Fetch <url> into <dest>, swapping in only a NON-EMPTY body so a blocked/failed
# fetch never clobbers a good cached list with an empty file. Built on the shared
# _router_fetch primitive (the ONE place the direct→tunnel fallback lives), so
# these lists load even when the router's direct path can't reach GitHub. -L:
# the github.com/.../releases/latest/download URLs 302 to objects.githubusercontent
# — without it curl writes the empty redirect body and the IP-CIDR rules never load.
_rule_fetch_to() {
    local dest="$1" url="$2"
    local tmp="$dest.new.$$"
    if _router_fetch "$url" "$tmp" -L && [ -s "$tmp" ]; then mv "$tmp" "$dest"; else rm -f "$tmp"; fi
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
    local tmp_raw="$SR_RULES_DIR/domains.raw.$$"
    : > "$tmp_dl"
    if _router_fetch "$url" "$tmp_raw"; then
        awk 'NF && !/^#/ && !/^!/ {gsub(/[[:space:]]+/, "", $0); if(length($0)) print "DOMAIN-SUFFIX," $0}' \
            "$tmp_raw" > "$tmp_dl"
    fi
    rm -f "$tmp_raw"
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
    # Same direct→tunnel fallback (via _rule_fetch_to → _router_fetch) so these
    # load on an uplink where the router's direct path can't reach GitHub.
    # _rule_fetch_to passes -L, so the github.com/.../releases/latest/download/ →
    # objects.github 302 is followed (without it curl writes the empty redirect
    # body and the Meta/Telegram IP-CIDR bypass rules silently never load).
    _rule_fetch_to "$SR_RULES_DIR/telegram.list" \
        "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Shadowrocket/Telegram/Telegram.list"
    _rule_fetch_to "$SR_RULES_DIR/discord.list" \
        "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/refs/heads/master/rule/Shadowrocket/Discord/Discord.list"
    _rule_fetch_to "$SR_RULES_DIR/meta_ips.list" \
        "https://github.com/toneywhitez/zkeen_rules/releases/latest/download/meta_ips.list"
    _rule_fetch_to "$SR_RULES_DIR/telegram_ips.list" \
        "https://github.com/toneywhitez/zkeen_rules/releases/latest/download/telegram_ips.list"
}
