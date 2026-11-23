#!/bin/ash
# EclipVPN — built-in domain lists (data only, no logic). Sourced into
# /usr/bin/eclipvpn; rules.sh turns these into routing rules. Shell heredocs
# rather than plain text files on purpose: the self-updater of already released
# versions runs `ash -n` over every manifest entry, so a non-shell file in
# packaging/ship-files would make their updates fail validation.

# RU services that go direct (clash-style rules).
_builtin_ru_domains() {
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
# Steam (not an RU service, but fully reachable direct in RU — none of its
# domains are in the RKN registry, verified vs itdoginfo/allow-domains
# 2026-07-07 — and SteamPipe downloads have RU CDN nodes, so direct is far
# faster than dragging multi-GB downloads through the VPN exit. dns-direct
# (Yandex) resolution is what hands out those nearby CDN endpoints.)
DOMAIN-SUFFIX,steampowered.com
DOMAIN-SUFFIX,steamcommunity.com
DOMAIN-SUFFIX,steamstatic.com
DOMAIN-SUFFIX,steamcontent.com
DOMAIN-SUFFIX,steamusercontent.com
DOMAIN-SUFFIX,steamserver.net
DOMAIN-SUFFIX,steam-chat.com
DOMAIN-SUFFIX,steamgames.com
DOMAIN-SUFFIX,s.team
DOMAIN-SUFFIX,valvesoftware.com
RUEOF
}

# Force-VPN list: AI / chat services + YouTube, one domain suffix per line.
_builtin_vpn_domains() {
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
}
