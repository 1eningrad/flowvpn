#!/bin/sh
# Bootstrap a new EclipVPN router from local sources (Mac → router via SSH),
# bypassing the private GitHub repo. Equivalent of install.sh but ships local
# COMMITTED bytes (git archive HEAD) instead of fetching tarballs from raw.github.
# (Was "the working tree" — now committed-only to dodge Yandex.Disk mid-sync
# corruption; set ALLOW_DIRTY=1 to ship uncommitted WIP, see the gate below.)
#
# Usage:
#   sh install-from-mac.sh                              # default: root@192.168.2.1
#   ROUTER=root@192.168.1.1 sh install-from-mac.sh      # factory-reset router
#   WITH_REMOTE=0 sh install-from-mac.sh                # skip Tailscale step
#
# Mac prereq: passwordless ssh root@<router> works (factory Routerich allows
# it on LAN). After a factory reset, run with ROUTER=root@192.168.1.1.
set -eu

ROUTER="${ROUTER:-root@192.168.2.1}"
SRC="$(cd "$(dirname "$0")" && pwd)"
WITH_REMOTE="${WITH_REMOTE:-1}"

cd "$SRC"

echo "→ ship sources to $ROUTER"
# NOTE: deliberately NOT /etc/eclipvpn here — the migration below preserves
# the old /etc/flowvpn config only when /etc/eclipvpn does not exist yet.
# Pre-creating it (even empty) used to flip the migration into its rm -rf
# branch and destroy the subscription.
ssh "$ROUTER" 'mkdir -p /usr/lib/eclipvpn /www/eclipvpn /www/flowvpn /www/cgi-bin /tmp/eclipvpn'

# Ship committed bytes, not the working tree — this repo lives inside a Yandex.Disk
# sync folder and a mid-sync (truncated/zero-byte) file once broke a deploy.
# `git archive` reads the immutable object store. Clean tree ships HEAD;
# ALLOW_DIRTY=1 ships the working tree (racy, opt-in). Scoped to TRACKED changes
# under the shipped trees (untracked files never enter git archive HEAD).
DIRTY=$(git status --porcelain --untracked-files=no -- usr www etc)
SHIP=git
if [ -n "$DIRTY" ]; then
    if [ "${ALLOW_DIRTY:-0}" = 1 ]; then
        echo "WARNING: working tree dirty + ALLOW_DIRTY=1 → shipping working tree (NOT immune to Yandex.Disk mid-sync corruption)" >&2
        SHIP=worktree
    else
        echo "ERROR: uncommitted changes under usr/ www/ etc/." >&2
        echo "       This bootstrap ships committed bytes (git archive HEAD)." >&2
        echo "       Commit first, or set ALLOW_DIRTY=1 to ship the working tree (racy)." >&2
        exit 1
    fi
fi

# Router shell files to ship — single source of truth (packaging/ship-files).
SHIP_FILES=$(grep -v '^#' packaging/ship-files | grep -v '^$')

# Buffer archive + UI to temp files and check exit codes BEFORE shipping: plain
# sh has no pipefail, so a failed `git archive`/`git show` would emit 0 bytes,
# the remote `tar x`/`cat >` would succeed (shipping nothing / blanking the UI),
# and set -e would never trip.
TARBALL=$(mktemp) || exit 1
UITMP=$(mktemp) || { rm -f "$TARBALL"; exit 1; }
if [ "$SHIP" = git ]; then
    git archive --format=tar HEAD -- $SHIP_FILES > "$TARBALL" || {
        echo "ERROR: git archive HEAD failed — a path in \$SHIP_FILES not committed?" >&2
        rm -f "$TARBALL" "$UITMP"; exit 1; }
    git show HEAD:www/eclipvpn/index.html > "$UITMP" || {
        echo "ERROR: git show HEAD:www/eclipvpn/index.html failed" >&2
        rm -f "$TARBALL" "$UITMP"; exit 1; }
else
    COPYFILE_DISABLE=1 tar c $SHIP_FILES > "$TARBALL" || {
        echo "ERROR: tar of \$SHIP_FILES failed" >&2; rm -f "$TARBALL" "$UITMP"; exit 1; }
    cat www/eclipvpn/index.html > "$UITMP" || {
        echo "ERROR: reading UI failed" >&2; rm -f "$TARBALL" "$UITMP"; exit 1; }
fi
{ [ -s "$TARBALL" ] && [ -s "$UITMP" ]; } || {
    echo "ERROR: empty archive or UI — aborting before it ships/blanks the router" >&2
    rm -f "$TARBALL" "$UITMP"; exit 1; }
ssh "$ROUTER" 'cd / && tar x' < "$TARBALL"
ssh "$ROUTER" 'cat > /www/eclipvpn/index.html' < "$UITMP"
rm -f "$TARBALL" "$UITMP"

echo "→ install dependencies + xray + Tailscale on router"
ssh "$ROUTER" "WITH_REMOTE=$WITH_REMOTE sh -s" <<'REMOTE_EOF'
set -eu

# Migrate an old "flowvpn"-named install (pre-2026.06) to the new eclipvpn
# paths before installing. Idempotent.
if [ -e /usr/bin/flowvpn ] || [ -d /etc/flowvpn ] || [ -e /etc/init.d/flowvpn ]; then
    echo "[0/5] Migrating old flowvpn install -> eclipvpn..."
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
    crontab -l 2>/dev/null | grep -v '/usr/bin/flowvpn ' | crontab - 2>/dev/null || true
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
             && ! grep -q '"subscription_url": *"http' /etc/eclipvpn/config.json 2>/dev/null; then
            # /etc/eclipvpn already exists (pre-created dir, or an untouched
            # default config minted by a stray CGI hit between ship and
            # migrate) — adopt the old install's files instead of nuking them.
            cp -a /etc/flowvpn/. /etc/eclipvpn/
            rm -rf /etc/flowvpn
        else
            rm -rf /etc/flowvpn
        fi
    fi
    rm -rf /usr/bin/flowvpn /usr/lib/flowvpn /etc/init.d/flowvpn /www/cgi-bin/flowvpn /tmp/flowvpn
fi

echo "[1/5] package deps (apk or opkg)"
# OpenWrt 25.x uses apk, older uses opkg. curl + ca-bundle are hard runtime
# deps that were previously missing from this list.
if command -v apk >/dev/null 2>&1; then PKG_INSTALL="apk add"; apk update >/dev/null 2>&1 || true
elif command -v opkg >/dev/null 2>&1; then PKG_INSTALL="opkg install"; opkg update >/dev/null 2>&1 || true
else echo "ERROR: no package manager (apk/opkg)"; exit 1; fi
$PKG_INSTALL jq curl ca-bundle coreutils-base64 kmod-nft-tproxy sing-box unzip 2>&1 | grep -E "Installing|installed|Installed" || true
for b in jq curl sing-box; do command -v "$b" >/dev/null 2>&1 || { echo "ERROR: dependency '$b' missing after install"; exit 1; }; done

echo "[2/5] xray 26.4.17"
ARCH=$(uname -m)
case "$ARCH" in
    aarch64)   XRAY_ARCH="arm64-v8a" ;;
    armv7l)    XRAY_ARCH="arm32-v7a" ;;
    x86_64)    XRAY_ARCH="64" ;;
    i386|i686) XRAY_ARCH="32" ;;
    mips)      XRAY_ARCH="mips32" ;;
    mipsel)    XRAY_ARCH="mips32le" ;;
    riscv64)   XRAY_ARCH="riscv64" ;;
    *)         echo "ERROR: unsupported arch $ARCH"; exit 1 ;;
esac
cd /tmp
wget -q "https://github.com/XTLS/Xray-core/releases/download/v26.4.17/Xray-linux-${XRAY_ARCH}.zip" -O xray.zip
unzip -o xray.zip xray -d /tmp/ >/dev/null
# Stage + mv: cp into a running xray's inode fails with ETXTBSY on upgrades;
# rename always succeeds and the live process keeps its old inode.
cp /tmp/xray /usr/bin/xray.new
chmod +x /usr/bin/xray.new
mv /usr/bin/xray.new /usr/bin/xray
rm -f /tmp/xray.zip /tmp/xray
echo "  installed: $(/usr/bin/xray version 2>&1 | head -1)"

echo "[3/5] permissions + initial config"
chmod +x /usr/bin/eclipvpn /etc/init.d/eclipvpn /www/cgi-bin/eclipvpn /usr/lib/eclipvpn/*.sh
/usr/bin/eclipvpn >/dev/null 2>&1 || true  # creates default config

# legacy /flowvpn/ → /eclipvpn/ redirect for old bookmarks
cat > /www/flowvpn/index.html <<'HTML'
<!DOCTYPE html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0;url=/eclipvpn/">
<title>EclipVPN</title>
<p>Адрес изменился. Открываю <a href="/eclipvpn/">/eclipvpn/</a>…</p>
HTML

# Raise uhttpd idle timeout — a large multi-subscription pool makes `eclipvpn
# ping` take 30-50s and the default network_timeout=30 kills the CGI mid-sweep
# (UI shows no pings). 90s fits, matches the UI fetch timeout. Idempotent.
if [ "$(uci -q get uhttpd.main.network_timeout)" != "90" ]; then
    uci set uhttpd.main.network_timeout=90
    uci commit uhttpd
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi

echo "[4/5] RemoteRouteRich (Tailscale)"
if [ "${WITH_REMOTE:-0}" = "1" ] && grep -q "DISTRIB_ID='RouteRich'" /etc/openwrt_release 2>/dev/null; then
    if ! opkg list-installed 2>/dev/null | grep -q '^tailscale-lite'; then
        opkg install tailscale-lite luci-app-tailscale luci-i18n-tailscale-ru 2>&1 | grep -E "Installing|installed" || true
    fi
    uci set tailscale.settings.login_server='https://rc.routerich.ru/'
    uci set tailscale.settings.enabled='1'
    uci commit tailscale
    /etc/init.d/tailscale enable >/dev/null 2>&1 || true
    /etc/init.d/tailscale restart
    sleep 4
    AUTH_URL=$(tailscale status 2>&1 | awk '/Log in at:/ {print $4}')
    [ -n "$AUTH_URL" ] && echo "  TAILSCALE_AUTH_URL: $AUTH_URL"
fi

echo "[5/5] enable autostart"
/etc/init.d/eclipvpn enable

echo
echo "===== INSTALL DONE ====="
echo "next steps (Mac side):"
echo "  1) on first router: ssh root@192.168.1.1 'eclipvpn backup' > ~/eclip-config.json"
echo "  2) restore here:    cat ~/eclip-config.json | ssh root@$(uci -q get network.lan.ipaddr || echo 192.168.2.1) 'eclipvpn restore'"
echo "     (cat|ssh, not scp — OpenWrt dropbear has no sftp-server)"
REMOTE_EOF

echo
echo "✓ install done — UI at http://${ROUTER#*@}/eclipvpn/"
echo "  если выше есть TAILSCALE_AUTH_URL — открой его в браузере и подставь свежий Device Auth Key"
