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

echo "→ git pull"
git pull --rebase --autostash 2>&1 | tail -3

echo "→ ship scripts/cgi/init.d to $ROUTER"
# COPYFILE_DISABLE=1 keeps macOS BSD tar from embedding `._*` AppleDouble
# resource forks; they end up next to every shipped file on the router and
# clutter /usr/lib/eclipvpn (the dispatcher only sources by exact filename,
# so they're inert — just noise).
COPYFILE_DISABLE=1 tar c \
    usr/bin/eclipvpn \
    usr/lib/eclipvpn/parse.sh \
    usr/lib/eclipvpn/xray.sh \
    usr/lib/eclipvpn/singbox.sh \
    usr/lib/eclipvpn/network.sh \
    etc/init.d/eclipvpn \
    www/cgi-bin/eclipvpn \
| ssh "$ROUTER" 'cd / && tar x'

echo "→ ship UI"
cat www/eclipvpn/index.html | ssh "$ROUTER" 'cat > /www/eclipvpn/index.html'

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
    nft delete table ip flowvpn_dns 2>/dev/null || true
    rm -f /tmp/dnsmasq.d/flowvpn.conf
    if [ -d /etc/flowvpn ] && [ ! -e /etc/eclipvpn ]; then
        mv /etc/flowvpn /etc/eclipvpn
    elif [ -d /etc/flowvpn ]; then
        rm -rf /etc/flowvpn
    fi
    rm -rf /usr/bin/flowvpn /usr/lib/flowvpn /etc/init.d/flowvpn /www/cgi-bin/flowvpn /tmp/flowvpn
fi

chmod +x /usr/bin/eclipvpn /etc/init.d/eclipvpn /www/cgi-bin/eclipvpn

# Syntax check before touching live state — bail before stop if anything broke.
for f in /usr/bin/eclipvpn /usr/lib/eclipvpn/parse.sh /usr/lib/eclipvpn/xray.sh \
         /usr/lib/eclipvpn/singbox.sh /usr/lib/eclipvpn/network.sh /etc/init.d/eclipvpn; do
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

# Wipe runtime state so rules + configs regenerate from new code.
rm -rf /tmp/eclipvpn/rules \
       /tmp/eclipvpn/watchdog.lock /tmp/eclipvpn/watchdog.pid /tmp/eclipvpn/watchdog.lockdir

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
