#!/bin/sh
# EclipVPN installer for OpenWrt
#
# Public repo:
#   curl -sSL https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh | sh
#
# Private repo (use a fine-grained PAT, read-only "Contents").
# Note the double quotes around the header — single quotes would send the
# literal string $REPO_TOKEN — and the explicit REPO_TOKEN= re-export into
# the piped sh, whose environment is separate from the curl command:
#   REPO_TOKEN=ghp_xxxxx; curl -sSL -H "Authorization: Bearer $REPO_TOKEN" \
#     https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh \
#     | REPO_TOKEN="$REPO_TOKEN" sh

set -e

REPO="https://raw.githubusercontent.com/1eningrad/flowvpn/main"
# Private-repo auth: the header value contains spaces ("Bearer <token>"), so
# it cannot live in a flat $WGET_AUTH string — unquoted expansion split it
# into three words and busybox wget treated "Bearer" and the token as extra
# URLs, sending no auth at all. A function keeps the argument intact.
fetch() {
    if [ -n "${REPO_TOKEN:-}" ]; then
        wget -q --header="Authorization: Bearer $REPO_TOKEN" "$1" -O "$2"
    else
        wget -q "$1" -O "$2"
    fi
}

ARCH=$(uname -m)

echo "=============================="
echo "  EclipVPN Installer"
echo "=============================="
echo ""

# Check OpenWrt
if [ ! -f /etc/openwrt_release ]; then
    echo "ERROR: This script is for OpenWrt only"
    exit 1
fi

# Migrate an old "flowvpn"-named install (pre-2026.06) to the new eclipvpn
# paths: stop+disable the old service, kill its watchdog, clean its nft/dnsmasq
# state, move config (preserving subscription/settings), remove old files.
# Idempotent — safe if no old install exists.
OLD_ENABLED=0
if [ -e /usr/bin/flowvpn ] || [ -d /etc/flowvpn ] || [ -e /etc/init.d/flowvpn ]; then
    echo "[0/6] Migrating old flowvpn install -> eclipvpn..."
    # Remember whether the old service auto-started so we can re-enable the
    # new one at the end — `disable` below would otherwise silently turn a
    # boot-surviving install into a manual-start one.
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
    # Old cron entries point at the binary we're about to delete. The new
    # ones are re-created from config by _ensure_cron_state on first start.
    crontab -l 2>/dev/null | grep -v '/usr/bin/flowvpn ' | crontab - 2>/dev/null || true
    if [ -f /tmp/dnsmasq.d/flowvpn.conf ]; then
        # Drop-in removal has no effect until dnsmasq rereads its conf-dir —
        # restart it so a redirect to the (now dead) old sing-box doesn't
        # keep LAN DNS broken until the user starts the new service.
        rm -f /tmp/dnsmasq.d/flowvpn.conf
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
    fi
    if [ -d /etc/flowvpn ]; then
        if [ ! -e /etc/eclipvpn ]; then
            mv /etc/flowvpn /etc/eclipvpn
        elif [ -f /etc/flowvpn/config.json ] \
             && ! grep -q '"subscription_url": *"http' /etc/eclipvpn/config.json 2>/dev/null; then
            # /etc/eclipvpn already exists (pre-created dir, or an untouched
            # default config) — adopt the old install's files instead of
            # discarding the user's subscription/settings.
            cp -a /etc/flowvpn/. /etc/eclipvpn/
            rm -rf /etc/flowvpn
        else
            rm -rf /etc/flowvpn
        fi
    fi
    rm -rf /usr/bin/flowvpn /usr/lib/flowvpn /etc/init.d/flowvpn /www/cgi-bin/flowvpn /tmp/flowvpn
fi

echo "[1/6] Installing dependencies..."
# OpenWrt 24.10+/25.x replaced opkg with apk (apk-tools 3). Detect either so
# the installer works on both. opkg-only broke silently on modern firmware.
if command -v apk >/dev/null 2>&1; then
    PKG_INSTALL="apk add"; apk update >/dev/null 2>&1 || true
elif command -v opkg >/dev/null 2>&1; then
    PKG_INSTALL="opkg install"; opkg update >/dev/null 2>&1 || true
else
    echo "ERROR: no package manager (apk/opkg) found"; exit 1
fi
# curl is a hard runtime dependency (subscription fetch, all probes, Clash
# API, rule-set downloads) and is NOT in busybox base — it was missing here.
$PKG_INSTALL jq curl ca-bundle coreutils-base64 kmod-nft-tproxy sing-box 2>&1 | grep -E "Installing|installed|Installed" || true
# Hard-verify mandatory binaries — the grep above can swallow a failed install.
for b in jq curl sing-box; do
    command -v "$b" >/dev/null 2>&1 || { echo "ERROR: required dependency '$b' missing after install ($PKG_INSTALL)"; exit 1; }
done

echo "[2/6] Installing xray-core 26.4.17..."
case "$ARCH" in
    aarch64)   XRAY_ARCH="arm64-v8a" ;;
    armv7l)    XRAY_ARCH="arm32-v7a" ;;
    x86_64)    XRAY_ARCH="64" ;;
    i386|i686) XRAY_ARCH="32" ;;
    # mips endianness isn't reliably distinguishable via uname -m on all
    # builds; this covers the common case (BE=mips32, LE=mipsel→mips32le).
    mips)      XRAY_ARCH="mips32" ;;
    mipsel)    XRAY_ARCH="mips32le" ;;
    riscv64)   XRAY_ARCH="riscv64" ;;
    *)         echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
esac

XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/v26.4.17/Xray-linux-${XRAY_ARCH}.zip"
cd /tmp
wget -q "$XRAY_URL" -O xray.zip || { echo "ERROR: Failed to download xray"; exit 1; }

# busybox has no unzip; install via whichever package manager this firmware
# uses. The old fallback hardcoded `opkg`, which doesn't exist on apk-based
# 25.x — exit 127 under set -e with both streams nulled, i.e. a silent abort.
if ! command -v unzip >/dev/null 2>&1; then
    $PKG_INSTALL unzip >/dev/null 2>&1 || true
    command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip missing and '$PKG_INSTALL unzip' failed"; exit 1; }
fi
unzip -o xray.zip xray -d /tmp/ >/dev/null
# Integrity check before installing over the live binary. Without a published
# sha256 (which would also vary per arch) we at least verify it's an ELF
# executable that self-reports the exact pinned version — this rejects an HTML
# error page, a truncated/blocked download, or a wrong-arch/tampered binary
# instead of mv'ing garbage onto /usr/bin/xray. Not a substitute for a signature.
if [ "$(dd if=/tmp/xray bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')" != "7f454c46" ]; then
    echo "ERROR: downloaded xray is not an ELF binary (blocked or garbage download)"; rm -f /tmp/xray.zip /tmp/xray; exit 1
fi
chmod +x /tmp/xray
if ! /tmp/xray version 2>/dev/null | grep -q "26.4.17"; then
    echo "ERROR: xray integrity check failed — binary does not report version 26.4.17"; rm -f /tmp/xray.zip /tmp/xray; exit 1
fi
# Stage + mv instead of cp-in-place: writing into a running xray's inode
# fails with ETXTBSY (upgrade over a live install); rename is always allowed
# and the running process keeps its old inode until the next restart.
cp /tmp/xray /usr/bin/xray.new
chmod +x /usr/bin/xray.new
mv /usr/bin/xray.new /usr/bin/xray
rm -f /tmp/xray.zip /tmp/xray
echo "  xray $(/usr/bin/xray version 2>&1 | head -1)"

echo "[3/6] Downloading EclipVPN..."
# /www/eclipvpn/ is the canonical UI path (rebrand April 2026).
# /www/flowvpn/index.html stays as a meta-refresh redirect for old bookmarks.
mkdir -p /usr/lib/eclipvpn /www/eclipvpn /www/flowvpn /www/cgi-bin /etc/eclipvpn /tmp/eclipvpn

# Files where source path == destination path. The list is the single ship
# manifest (packaging/ship-files) — fetch it from GitHub raw first, then loop,
# so this list can never drift from deploy.sh / install-from-mac.sh.
fetch "$REPO/packaging/ship-files" /tmp/eclip-ship-files \
    || { echo "ERROR: Failed to download file manifest"; exit 1; }
for file in $(grep -v '^#' /tmp/eclip-ship-files | grep -v '^$'); do
    fetch "$REPO/$file" "/$file" || { echo "ERROR: Failed to download $file"; exit 1; }
    chmod +x "/$file"
done
rm -f /tmp/eclip-ship-files

# UI: source www/eclipvpn/index.html → install to /www/eclipvpn/index.html
fetch "$REPO/www/eclipvpn/index.html" /www/eclipvpn/index.html \
    || { echo "ERROR: Failed to download UI"; exit 1; }

# Backward-compat redirect for /eclipvpn/ bookmarks.
cat > /www/flowvpn/index.html <<'EOF'
<!DOCTYPE html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0;url=/eclipvpn/">
<title>EclipVPN</title>
<p>Адрес изменился. Открываю <a href="/eclipvpn/">/eclipvpn/</a>…</p>
EOF

# Build stamp — install.sh runs on the router with no git checkout, so record
# what it can (branch + install date). deploy.sh / installer.exe carry the SHA.
printf 'main installed=%s via=install.sh\n' "$(date -u +%Y-%m-%d 2>/dev/null || echo '?')" > /etc/eclipvpn/build
chmod 644 /etc/eclipvpn/build

echo "[4/6] Initial configuration..."
/usr/bin/eclipvpn >/dev/null 2>&1 || true  # Creates default config

# Migrated installs keep their boot behavior: the old service was disabled
# in [0/6], so re-enable the new one if the old one auto-started.
if [ "$OLD_ENABLED" = "1" ]; then
    /etc/init.d/eclipvpn enable >/dev/null 2>&1 || true
    echo "  autostart re-enabled (migrated from flowvpn)"
fi

# Raise uhttpd's idle timeout. With a large multi-subscription server pool
# `eclipvpn ping` probes every server and can take 30-50s; the default
# network_timeout=30 kills the CGI mid-sweep, so the UI shows no pings. 90s
# fits and matches the UI fetch timeout. Idempotent: only restart if changed.
if [ "$(uci -q get uhttpd.main.network_timeout)" != "90" ]; then
    uci set uhttpd.main.network_timeout=90
    uci commit uhttpd
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true
    echo "  uhttpd network_timeout → 90s (for large server pools)"
fi

echo "[5/6] Optional: RemoteRouteRich (always-on remote access via vendor Tailscale)..."
# Vendor-hosted Headscale at rc.routerich.ru — works under CGNAT, no white IP, free.
# Opt-in: WITH_REMOTE=1 sh install.sh. Only works on RouteRich firmware (their opkg
# repo ships tailscale-lite + luci-app-tailscale; stock OpenWrt does not).
if [ "$WITH_REMOTE" = "1" ]; then
    if grep -q "DISTRIB_ID='RouteRich'" /etc/openwrt_release 2>/dev/null; then
        if ! opkg list-installed 2>/dev/null | grep -q '^tailscale-lite'; then
            opkg install tailscale-lite luci-app-tailscale luci-i18n-tailscale-ru 2>&1 \
                | grep -E "Installing|installed" || true
        else
            echo "  tailscale already installed, reusing"
        fi
        uci set tailscale.settings.login_server='https://rc.routerich.ru/'
        uci set tailscale.settings.enabled='1'
        uci commit tailscale
        /etc/init.d/tailscale enable >/dev/null 2>&1 || true
        /etc/init.d/tailscale restart
        sleep 4
        AUTH_URL=$(tailscale status 2>&1 | awk '/Log in at:/ {print $4}')
        if [ -n "$AUTH_URL" ]; then
            echo "  Авторизуй роутер: $AUTH_URL"
            echo "  (если tailnet ещё нет — создай на https://remote.routerich.ru/create-tailnet)"
        else
            echo "  Tailscale запущен. Статус: tailscale status"
        fi
    else
        echo "  пропущено: не RouteRich-прошивка (tailscale-lite доступен только в их opkg)"
    fi
else
    echo "  пропущено (для включения: WITH_REMOTE=1 sh install.sh)"
fi

echo "[6/6] Done!"
echo ""
echo "=============================="
echo "  EclipVPN installed!"
echo "=============================="
echo ""
echo "Next steps:"
echo "  1. Set your subscription URL:"
echo "     eclipvpn set-config subscription_url 'https://your-url'"
echo ""
echo "  2. Update servers:"
echo "     eclipvpn update"
echo ""
echo "  3. Start VPN:"
echo "     eclipvpn start"
echo ""
echo "  4. Open Web UI:"
LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
echo "     http://${LAN_IP:-router-ip}/eclipvpn/"
echo ""
echo "  5. Enable autostart:"
echo "     /etc/init.d/eclipvpn enable"
echo ""
