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
# clutter /usr/lib/flowvpn (the dispatcher only sources by exact filename,
# so they're inert — just noise).
COPYFILE_DISABLE=1 tar c \
    usr/bin/flowvpn \
    usr/lib/flowvpn/parse.sh \
    usr/lib/flowvpn/xray.sh \
    usr/lib/flowvpn/singbox.sh \
    usr/lib/flowvpn/network.sh \
    etc/init.d/flowvpn \
    www/cgi-bin/flowvpn \
| ssh "$ROUTER" 'cd / && tar x'

echo "→ ship UI"
cat www/flowvpn/index.html | ssh "$ROUTER" 'cat > /www/eclipvpn/index.html'

echo "→ apply on router"
ssh "$ROUTER" 'set -eu

chmod +x /usr/bin/flowvpn /etc/init.d/flowvpn /www/cgi-bin/flowvpn

# Syntax check before touching live state — bail before stop if anything broke.
for f in /usr/bin/flowvpn /usr/lib/flowvpn/parse.sh /usr/lib/flowvpn/xray.sh \
         /usr/lib/flowvpn/singbox.sh /usr/lib/flowvpn/network.sh /etc/init.d/flowvpn; do
    ash -n "$f" || { echo "SYNTAX FAIL: $f" >&2; exit 1; }
done

# Graceful stop via init.d (uses watchdog.pid/.lock from old layout).
/etc/init.d/flowvpn stop >/dev/null 2>&1 || true
sleep 1

# Force-kill any watchdog the old code left behind. Self-exclusion via
# explicit cmdline match: only kills processes whose argv joins to
# "/bin/ash /usr/bin/flowvpn watchdog ...".
for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    case $(tr "\0" " " < "$p/cmdline") in
        "/bin/ash /usr/bin/flowvpn watchdog"*)
            kill -9 "${p##*/}" 2>/dev/null || true
            ;;
    esac
done

# Wipe runtime state so rules + configs regenerate from new code.
rm -rf /tmp/flowvpn/rules \
       /tmp/flowvpn/watchdog.lock /tmp/flowvpn/watchdog.pid /tmp/flowvpn/watchdog.lockdir

/etc/init.d/flowvpn restart
sleep 5

echo
echo "=== processes ==="
ps w | grep -E "/usr/bin/xray|/usr/bin/sing-box|/usr/bin/flowvpn watchdog" | grep -v grep || echo "(none?)"
echo
echo "=== watchdog lockdir owner ==="
cat /tmp/flowvpn/watchdog.lockdir/owner 2>/dev/null || echo "(missing)"
echo
echo "=== ru direct list ==="
wc -l /tmp/flowvpn/rules/ru_domains.list 2>/dev/null || echo "(not generated yet)"
echo
echo "=== logs (warn level — should be small) ==="
wc -l /tmp/flowvpn/*.log 2>/dev/null || echo "(no logs yet)"
echo
echo "=== flowvpn status ==="
/usr/bin/flowvpn status 2>/dev/null | head -10
'

echo
echo "✓ deploy done — open http://${ROUTER#*@}/eclipvpn/ to verify UI"
