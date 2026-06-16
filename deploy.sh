#!/bin/sh
# One-shot rollout to a running EclipVPN router.
# Pulls latest from git, ships scripts + CGI + UI, force-cleans stale
# state, restarts via init.d, prints verification.
#
# Usage:
#   ./deploy.sh                   # default: root@192.168.1.1
#   ROUTER=root@10.0.0.1 ./deploy.sh
#
# Designed to be safe to run repeatedly — every step is idempotent.
set -eu

ROUTER="${ROUTER:-root@192.168.1.1}"
cd "$(dirname "$0")"

# SKIP_PULL=1 ships the current working tree as-is, without syncing git first.
# Use it to deploy uncommitted local changes (e.g. to a test router) or when the
# git remote is unreachable (GitHub is blocked from inside RU).
if [ "${SKIP_PULL:-0}" = 1 ]; then
    echo "→ skip git pull (SKIP_PULL=1) — shipping working tree as-is"
else
    echo "→ git pull"
    # Capture instead of piping straight to tail: without pipefail (plain sh),
    # set -e only sees tail's exit code and a failed/conflicted pull would
    # silently deploy whatever half-state is on disk.
    PULL_OUT=$(git pull --rebase --autostash 2>&1) || {
        printf '%s\n' "$PULL_OUT"
        echo "ERROR: git pull failed — resolve before deploying (or re-run with SKIP_PULL=1)" >&2
        exit 1
    }
    printf '%s\n' "$PULL_OUT" | tail -3
fi

echo "→ ship scripts/cgi/init.d to $ROUTER"
# COPYFILE_DISABLE=1 keeps macOS BSD tar from embedding `._*` AppleDouble
# resource forks; they end up next to every shipped file on the router and
# clutter /usr/lib/eclipvpn (the dispatcher only sources by exact filename,
# so they're inert — just noise).
COPYFILE_DISABLE=1 tar c \
    usr/bin/eclipvpn \
    usr/lib/eclipvpn/parse.sh \
    usr/lib/eclipvpn/subscriptions.sh \
    usr/lib/eclipvpn/xray.sh \
    usr/lib/eclipvpn/singbox.sh \
    usr/lib/eclipvpn/network.sh \
    usr/lib/eclipvpn/watchdog.sh \
    usr/lib/eclipvpn/lifecycle.sh \
    usr/lib/eclipvpn/servers.sh \
    usr/lib/eclipvpn/domains.sh \
    usr/lib/eclipvpn/traffic.sh \
    usr/lib/eclipvpn/health.sh \
    usr/lib/eclipvpn/config.sh \
    etc/init.d/eclipvpn \
    www/cgi-bin/eclipvpn \
| ssh "$ROUTER" 'cd / && tar x'

echo "→ ship UI"
# mkdir -p first: on a router that only ever had the old flowvpn layout the
# directory doesn't exist yet, the redirect fails, and set -eu kills the
# deploy BEFORE the migration block below ever runs.
cat www/eclipvpn/index.html | ssh "$ROUTER" 'mkdir -p /www/eclipvpn && cat > /www/eclipvpn/index.html'

echo "→ apply on router"
ssh "$ROUTER" 'set -eu

# One-time migration from the old "flowvpn" internal naming (pre-2026.06).
# Stop+disable the old service, kill its watchdog, clean its nft tables +
# dnsmasq drop-in, move config to the new path (preserving config.json /
# clash_secret / domain lists / rules), and remove old files so they cannot
# run alongside the new ones. Idempotent — safe to re-run.
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

chmod +x /usr/bin/eclipvpn /etc/init.d/eclipvpn /www/cgi-bin/eclipvpn

# Syntax check before touching live state — bail before stop if anything broke.
for f in /usr/bin/eclipvpn /usr/lib/eclipvpn/parse.sh /usr/lib/eclipvpn/subscriptions.sh /usr/lib/eclipvpn/xray.sh \
         /usr/lib/eclipvpn/singbox.sh /usr/lib/eclipvpn/network.sh \
         /usr/lib/eclipvpn/watchdog.sh /usr/lib/eclipvpn/lifecycle.sh \
         /usr/lib/eclipvpn/servers.sh /usr/lib/eclipvpn/domains.sh \
         /usr/lib/eclipvpn/traffic.sh /usr/lib/eclipvpn/health.sh \
         /usr/lib/eclipvpn/config.sh /etc/init.d/eclipvpn; do
    ash -n "$f" || { echo "SYNTAX FAIL: $f" >&2; exit 1; }
done

# Graceful stop via init.d (uses watchdog.pid/.lock from old layout).
/etc/init.d/eclipvpn stop >/dev/null 2>&1 || true
sleep 1

# Force-kill any watchdog the old code left behind. Self-exclusion via
# explicit cmdline match: only kills processes whose argv joins to
# "/bin/ash /usr/bin/eclipvpn watchdog ...".
for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    case $(tr "\0" " " < "$p/cmdline") in
        "/bin/ash /usr/bin/eclipvpn watchdog"*)
            kill -9 "${p##*/}" 2>/dev/null || true
            ;;
    esac
done

# Wipe runtime state so rules + configs regenerate from new code. Includes the
# lock artifacts (incl. the now-retired op.lockdir from pre-symlink builds) so a
# stale lock from old code cannot wedge the new lock primitives after the swap.
rm -rf /tmp/eclipvpn/rules \
       /tmp/eclipvpn/watchdog.lock /tmp/eclipvpn/watchdog.pid /tmp/eclipvpn/watchdog.lockdir \
       /tmp/eclipvpn/op.lock /tmp/eclipvpn/op.lockdir /tmp/eclipvpn/op.in_progress /tmp/eclipvpn/op.reclaim.lockdir \
       /tmp/eclipvpn/config.lock /tmp/eclipvpn/config.reclaim.lockdir

# Preserve autostart if the old flowvpn install had it enabled.
[ "${OLD_ENABLED:-0}" = 1 ] && /etc/init.d/eclipvpn enable >/dev/null 2>&1 || true

/etc/init.d/eclipvpn restart
sleep 5

echo
echo "=== processes ==="
ps w | grep -E "/usr/bin/xray|/usr/bin/sing-box|/usr/bin/eclipvpn watchdog" | grep -v grep || echo "(none?)"
echo
echo "=== watchdog lockdir owner ==="
cat /tmp/eclipvpn/watchdog.lockdir/owner 2>/dev/null || echo "(missing)"
echo
echo "=== ru direct list ==="
wc -l /tmp/eclipvpn/rules/ru_domains.list 2>/dev/null || echo "(not generated yet)"
echo
echo "=== logs (warn level — should be small) ==="
wc -l /tmp/eclipvpn/*.log 2>/dev/null || echo "(no logs yet)"
echo
echo "=== eclipvpn status ==="
/usr/bin/eclipvpn status 2>/dev/null | head -10
'

echo
echo "✓ deploy done — open http://${ROUTER#*@}/eclipvpn/ to verify UI"
