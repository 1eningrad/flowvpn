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

echo "[1/5] Installing dependencies..."
opkg update >/dev/null 2>&1
opkg install jq coreutils-base64 kmod-nft-tproxy sing-box 2>&1 | grep -E "Installing|installed" || true

echo "[2/5] Installing xray-core 26.4.17..."
case "$ARCH" in
    aarch64) XRAY_ARCH="arm64-v8a" ;;
    armv7l)  XRAY_ARCH="arm32-v7a" ;;
    x86_64)  XRAY_ARCH="64" ;;
    *)       echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
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

echo "[3/5] Downloading EclipVPN..."
# /www/eclipvpn/ is the canonical UI path (rebrand April 2026).
# /www/flowvpn/index.html stays as a meta-refresh redirect for old bookmarks.
mkdir -p /usr/lib/flowvpn /www/eclipvpn /www/flowvpn /www/cgi-bin /etc/flowvpn /tmp/flowvpn

# Files where source path == destination path
for file in \
    usr/bin/flowvpn \
    usr/lib/flowvpn/parse.sh \
    usr/lib/flowvpn/xray.sh \
    usr/lib/flowvpn/singbox.sh \
    usr/lib/flowvpn/network.sh \
    www/cgi-bin/flowvpn \
    etc/init.d/flowvpn; do
    wget -q $WGET_AUTH "$REPO/$file" -O "/$file" || { echo "ERROR: Failed to download $file"; exit 1; }
    chmod +x "/$file"
done

# UI: source www/flowvpn/index.html → install to /www/eclipvpn/index.html
wget -q $WGET_AUTH "$REPO/www/flowvpn/index.html" -O /www/eclipvpn/index.html \
    || { echo "ERROR: Failed to download UI"; exit 1; }

# Backward-compat redirect for /flowvpn/ bookmarks.
cat > /www/flowvpn/index.html <<'EOF'
<!DOCTYPE html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0;url=/eclipvpn/">
<title>EclipVPN</title>
<p>Адрес изменился. Открываю <a href="/eclipvpn/">/eclipvpn/</a>…</p>
EOF

echo "[4/5] Initial configuration..."
/usr/bin/flowvpn >/dev/null 2>&1 || true  # Creates default config

echo "[5/5] Done!"
echo ""
echo "=============================="
echo "  EclipVPN installed!"
echo "=============================="
echo ""
echo "Next steps:"
echo "  1. Set your subscription URL:"
echo "     flowvpn set-config subscription_url 'https://your-url'"
echo ""
echo "  2. Update servers:"
echo "     flowvpn update"
echo ""
echo "  3. Start VPN:"
echo "     flowvpn start"
echo ""
echo "  4. Open Web UI:"
LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}')
echo "     http://${LAN_IP:-router-ip}/eclipvpn/"
echo ""
echo "  5. Enable autostart:"
echo "     /etc/init.d/flowvpn enable"
echo ""
