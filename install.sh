#!/bin/sh
# EclipVPN installer for OpenWrt
#
# Public repo:
#   curl -sSL https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh | sh
#
# Private repo (use a fine-grained PAT, read-only "Contents"):
#   REPO_TOKEN=ghp_xxxxx sh -c "$(curl -sSL \
#     -H 'Authorization: Bearer $REPO_TOKEN' \
#     https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh)"

set -e

REPO="https://raw.githubusercontent.com/1eningrad/flowvpn/main"
# wget needs explicit header for private repo. Empty when REPO_TOKEN unset.
WGET_AUTH=""
[ -n "$REPO_TOKEN" ] && WGET_AUTH="--header=Authorization: Bearer $REPO_TOKEN"

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
if [ -e /usr/bin/flowvpn ] || [ -d /etc/flowvpn ] || [ -e /etc/init.d/flowvpn ]; then
    echo "[0/6] Migrating old flowvpn install -> eclipvpn..."
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

if command -v unzip >/dev/null 2>&1; then
    unzip -o xray.zip xray -d /tmp/ >/dev/null
else
    opkg install unzip >/dev/null 2>&1
    unzip -o xray.zip xray -d /tmp/ >/dev/null
fi
cp /tmp/xray /usr/bin/xray
chmod +x /usr/bin/xray
rm -f /tmp/xray.zip /tmp/xray
echo "  xray $(/usr/bin/xray version 2>&1 | head -1)"

echo "[3/6] Downloading EclipVPN..."
# /www/eclipvpn/ is the canonical UI path (rebrand April 2026).
# /www/flowvpn/index.html stays as a meta-refresh redirect for old bookmarks.
mkdir -p /usr/lib/eclipvpn /www/eclipvpn /www/flowvpn /www/cgi-bin /etc/eclipvpn /tmp/eclipvpn

# Files where source path == destination path
for file in \
    usr/bin/eclipvpn \
    usr/lib/eclipvpn/parse.sh \
    usr/lib/eclipvpn/xray.sh \
    usr/lib/eclipvpn/singbox.sh \
    usr/lib/eclipvpn/network.sh \
    www/cgi-bin/eclipvpn \
    etc/init.d/eclipvpn; do
    wget -q $WGET_AUTH "$REPO/$file" -O "/$file" || { echo "ERROR: Failed to download $file"; exit 1; }
    chmod +x "/$file"
done

# UI: source www/eclipvpn/index.html → install to /www/eclipvpn/index.html
wget -q $WGET_AUTH "$REPO/www/flowvpn/index.html" -O /www/eclipvpn/index.html \
    || { echo "ERROR: Failed to download UI"; exit 1; }

# Backward-compat redirect for /eclipvpn/ bookmarks.
cat > /www/flowvpn/index.html <<'EOF'
<!DOCTYPE html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0;url=/eclipvpn/">
<title>EclipVPN</title>
<p>Адрес изменился. Открываю <a href="/eclipvpn/">/eclipvpn/</a>…</p>
EOF

echo "[4/6] Initial configuration..."
/usr/bin/eclipvpn >/dev/null 2>&1 || true  # Creates default config

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
