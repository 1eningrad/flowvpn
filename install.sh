#!/bin/sh
# FlowVPN installer for OpenWrt
# Usage: curl -sSL https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh | sh

set -e

REPO="https://raw.githubusercontent.com/1eningrad/flowvpn/main"
ARCH=$(uname -m)

echo "=============================="
echo "  FlowVPN Installer"
echo "=============================="
echo ""

# Check OpenWrt
if [ ! -f /etc/openwrt_release ]; then
    echo "ERROR: This script is for OpenWrt only"
    exit 1
fi

echo "[1/5] Installing dependencies..."
opkg update >/dev/null 2>&1
opkg install jq coreutils-base64 kmod-nft-tproxy sing-box 2>&1 | grep -E "Installing|installed"

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

# Try unzip, if not available — install it
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

echo "[3/5] Downloading FlowVPN..."
mkdir -p /usr/lib/flowvpn /www/flowvpn /etc/flowvpn /tmp/flowvpn

for file in \
    usr/bin/flowvpn \
    usr/lib/flowvpn/parse.sh \
    usr/lib/flowvpn/xray.sh \
    usr/lib/flowvpn/singbox.sh \
    usr/lib/flowvpn/network.sh \
    www/cgi-bin/flowvpn \
    www/flowvpn/index.html \
    etc/init.d/flowvpn; do
    wget -q "$REPO/$file" -O "/$file" || { echo "ERROR: Failed to download $file"; exit 1; }
    chmod +x "/$file"
done

echo "[4/5] Initial configuration..."
/usr/bin/flowvpn >/dev/null 2>&1 || true  # Creates default config

echo "[5/5] Done!"
echo ""
echo "=============================="
echo "  FlowVPN installed!"
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
echo "     http://${LAN_IP:-router-ip}/flowvpn/"
echo ""
echo "  5. Enable autostart:"
echo "     /etc/init.d/flowvpn enable"
echo ""
