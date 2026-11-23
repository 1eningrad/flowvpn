#!/bin/sh
# One-time migration from the old "flowvpn" naming (pre-2026.06). Shared by
# install.sh, install-from-mac.sh and deploy.sh; runs ON the router, spliced into
# or sourced by them. Dev-only: not installed. Idempotent, safe under `set -eu`.
# Sets OLD_ENABLED=1 if the old service auto-started, so the caller re-enables
# the new one. No single quotes in this file: deploy.sh splices it into a
# remote command string.
#
# Stops and disables the old service, kills its watchdog, cleans its nft tables,
# cron and dnsmasq drop-in, moves the config (preserving subscription, secret,
# lists), removes the old files and leaves a redirect for old bookmarks.
OLD_ENABLED=0
if [ -e /usr/bin/flowvpn ] || [ -d /etc/flowvpn ] || [ -e /etc/init.d/flowvpn ]; then
    echo "→ migrating old flowvpn install → eclipvpn"
    ls /etc/rc.d/S*flowvpn >/dev/null 2>&1 && OLD_ENABLED=1
    /etc/init.d/flowvpn stop >/dev/null 2>&1 || true
    /etc/init.d/flowvpn disable >/dev/null 2>&1 || true
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        case $(tr "\0" " " < "$p/cmdline") in
            "/bin/ash /usr/bin/flowvpn watchdog"*) kill -9 "${p##*/}" 2>/dev/null || true ;;
        esac
    done
    nft delete table ip flowvpn 2>/dev/null || true
    nft delete table inet flowvpn 2>/dev/null || true
    nft delete table ip flowvpn_dns 2>/dev/null || true
    # Old cron entries point at the binary deleted below; new ones are
    # re-created from config by _ensure_cron_state on first start.
    crontab -l 2>/dev/null | grep -v "/usr/bin/flowvpn " | crontab - 2>/dev/null || true
    if [ -f /tmp/dnsmasq.d/flowvpn.conf ]; then
        # dnsmasq only rereads conf-dir on restart — without it a redirect
        # to the dead old sing-box keeps LAN DNS broken until first start.
        rm -f /tmp/dnsmasq.d/flowvpn.conf
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    fi
    if [ -d /etc/flowvpn ]; then
        if [ ! -e /etc/eclipvpn ]; then
            mv /etc/flowvpn /etc/eclipvpn
        elif [ -f /etc/flowvpn/config.json ] \
             && ! grep -q "\"subscription_url\": *\"http" /etc/eclipvpn/config.json 2>/dev/null; then
            # /etc/eclipvpn already exists (pre-created dir, or an untouched
            # default config minted by a stray CGI hit between ship and
            # migrate) — adopt the old install instead of discarding it.
            cp -a /etc/flowvpn/. /etc/eclipvpn/
            rm -rf /etc/flowvpn
        else
            rm -rf /etc/flowvpn
        fi
    fi
    rm -rf /usr/bin/flowvpn /usr/lib/flowvpn /etc/init.d/flowvpn /www/cgi-bin/flowvpn /tmp/flowvpn
    # The old full SPA at /www/flowvpn/index.html would keep calling the
    # just-deleted /cgi-bin/flowvpn — replace it with the same redirect
    # stub the installers write.
    mkdir -p /www/flowvpn
    cat > /www/flowvpn/index.html <<REDIR
<!DOCTYPE html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0;url=/eclipvpn/">
<title>EclipVPN</title>
<p>Адрес изменился. Открываю <a href="/eclipvpn/">/eclipvpn/</a>…</p>
REDIR
fi
