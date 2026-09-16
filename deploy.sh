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

# SKIP_PULL=1 skips the `git pull` sync below — use it when the git remote is
# unreachable (GitHub is blocked from inside RU). It does NOT change WHAT ships:
# deploy always ships committed bytes (git archive HEAD). To deploy uncommitted
# local changes, set ALLOW_DIRTY=1 (ships the working tree — racy vs Yandex.Disk
# mid-sync; see the integrity gate after the pull block).
if [ "${SKIP_PULL:-0}" = 1 ]; then
    echo "→ skip git pull (SKIP_PULL=1)"
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

# Ship committed bytes, not the working tree. This repo lives inside a Yandex.Disk
# sync folder; tarring the working tree once shipped a half-synced rules.sh to the
# router and the tunnel never came up (2026-06-16). `git archive` reads the
# immutable object store, so a mid-sync (truncated/zero-byte) file can never reach
# the router. Default requires a clean tree (ships HEAD). ALLOW_DIRTY=1 falls back
# to the old working-tree tar for fast local iteration — racy, opt-in only. Scope
# the check to TRACKED modifications under the shipped trees: untracked files
# (Yandex.Disk conflict-copies, editor temps) never enter `git archive HEAD`, so
# they must not block a clean committed-bytes deploy; a genuinely-missing committed
# file is caught loudly by the archive rc-check below instead.
DIRTY=$(git status --porcelain --untracked-files=no -- usr www etc)
SHIP=git
if [ -n "$DIRTY" ]; then
    if [ "${ALLOW_DIRTY:-0}" = 1 ]; then
        echo "WARNING: working tree dirty + ALLOW_DIRTY=1 → shipping working tree (NOT immune to Yandex.Disk mid-sync corruption)" >&2
        SHIP=worktree
    else
        echo "ERROR: uncommitted changes under usr/ www/ etc/." >&2
        echo "       deploy ships committed bytes (git archive HEAD) to dodge the" >&2
        echo "       Yandex.Disk sync-corruption bug. Commit first, or set" >&2
        echo "       ALLOW_DIRTY=1 to ship the working tree as-is (racy)." >&2
        exit 1
    fi
fi

# Router shell files to ship — single source of truth (packaging/ship-files).
# A new lib goes in the manifest ONLY; every installer + the CI guard read it.
SHIP_FILES=$(grep -v '^#' packaging/ship-files | grep -v '^$')

echo "→ ship scripts/cgi/init.d to $ROUTER ($SHIP)"
# Buffer the archive to a temp file and check its exit code BEFORE shipping.
# Piping straight into ssh would hide a failure: plain sh has no pipefail, so a
# failed `git archive` (e.g. a $SHIP_FILES path not committed at HEAD) emits 0
# bytes, `tar x` succeeds on empty stdin, the pipeline returns 0, and set -e never
# trips — the router silently keeps the OLD code while the deploy reports success.
TARBALL=$(mktemp) || exit 1
if [ "$SHIP" = git ]; then
    git archive --format=tar HEAD -- $SHIP_FILES > "$TARBALL" || {
        echo "ERROR: git archive HEAD failed — a path in \$SHIP_FILES not committed (or typo'd)?" >&2
        rm -f "$TARBALL"; exit 1; }
else
    # COPYFILE_DISABLE=1 keeps macOS BSD tar from embedding `._*` AppleDouble
    # resource forks; they end up next to every shipped file on the router and
    # clutter /usr/lib/eclipvpn (the dispatcher only sources by exact filename,
    # so they're inert — just noise).
    COPYFILE_DISABLE=1 tar c $SHIP_FILES > "$TARBALL" || {
        echo "ERROR: tar of \$SHIP_FILES failed" >&2; rm -f "$TARBALL"; exit 1; }
fi
[ -s "$TARBALL" ] || { echo "ERROR: empty archive — nothing to ship, aborting" >&2; rm -f "$TARBALL"; exit 1; }
ssh "$ROUTER" 'cd / && tar x' < "$TARBALL"
rm -f "$TARBALL"

echo "→ ship UI"
# mkdir -p first: on a router that only ever had the old flowvpn layout the
# directory doesn't exist yet, the redirect fails, and set -eu kills the
# deploy BEFORE the migration block below ever runs.
# Same temp-file guard: a failed `git show` would otherwise pipe 0 bytes into
# `cat >` and BLANK the router's UI (white screen) while returning 0. Refuse to
# ship an empty index.html.
UITMP=$(mktemp) || exit 1
if [ "$SHIP" = git ]; then
    git show HEAD:www/eclipvpn/index.html > "$UITMP" || {
        echo "ERROR: git show HEAD:www/eclipvpn/index.html failed" >&2; rm -f "$UITMP"; exit 1; }
else
    cat www/eclipvpn/index.html > "$UITMP" || {
        echo "ERROR: reading www/eclipvpn/index.html failed" >&2; rm -f "$UITMP"; exit 1; }
fi
[ -s "$UITMP" ] || { echo "ERROR: UI index.html is empty — refusing to blank the router UI" >&2; rm -f "$UITMP"; exit 1; }
ssh "$ROUTER" 'mkdir -p /www/eclipvpn && cat > /www/eclipvpn/index.html' < "$UITMP"
rm -f "$UITMP"

# Build the remote syntax-check list from the SAME manifest that decided what
# to ship, instead of a second hardcoded glob (the router-side `for f in
# /usr/bin/eclipvpn ... /usr/lib/eclipvpn/*.sh` below) — a future manifest
# entry outside those fixed patterns (e.g. a new top-level script) would ship
# fine but silently skip the pre-flight ash -n gate, only surfacing a syntax
# error at runtime on the router. Same drift class CLAUDE.md already documents
# for the test runner enumerating suites by glob (found in review 2026-09-16).
# Prefix each manifest path with / to match where the tar unpacked it (root).
SYNTAX_CHECK_LIST=$(printf '/%s ' $SHIP_FILES)

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
# List spliced in from the LOCAL $SHIP_FILES (see SYNTAX_CHECK_LIST above) —
# genuinely manifest-driven now, not a second hardcoded pattern.
for f in '"$SYNTAX_CHECK_LIST"'; do
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
echo "=== logs (sing-box at info — drives the UI flow panel) ==="
wc -l /tmp/eclipvpn/*.log 2>/dev/null || echo "(no logs yet)"
echo
echo "=== eclipvpn status ==="
/usr/bin/eclipvpn status 2>/dev/null | head -10
'

# Stamp the build identity (the committed SHA + date that just shipped) into
# /etc/eclipvpn/build so `eclipvpn system-info` and the UI can tell exactly which
# build a router runs — ECLIPVPN_VERSION is a constant and never distinguishes
# two deploys of the same release.
BUILD_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
[ "$SHIP" = worktree ] && BUILD_SHA="$BUILD_SHA+dirty"
BUILD_STAMP="$BUILD_SHA $(git show -s --format=%cd --date=short HEAD 2>/dev/null) via=deploy.sh"
printf '%s\n' "$BUILD_STAMP" | ssh "$ROUTER" 'mkdir -p /etc/eclipvpn && cat > /etc/eclipvpn/build && chmod 644 /etc/eclipvpn/build'
echo "→ build: $BUILD_STAMP"

echo
echo "✓ deploy done — open http://${ROUTER#*@}/eclipvpn/ to verify UI"
