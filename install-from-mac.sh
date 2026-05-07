#!/bin/sh
# Bootstrap a new EclipVPN router from local sources (Mac → router via SSH),
# bypassing the private GitHub repo. Equivalent of install.sh but uses the
# working tree it lives in instead of fetching tarballs from raw.github.
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
ssh "$ROUTER" 'mkdir -p /usr/lib/flowvpn /www/eclipvpn /www/flowvpn /www/cgi-bin /etc/flowvpn /tmp/flowvpn'

COPYFILE_DISABLE=1 tar c \
    usr/bin/flowvpn \
    usr/lib/flowvpn/parse.sh \
    usr/lib/flowvpn/xray.sh \
    usr/lib/flowvpn/singbox.sh \
    usr/lib/flowvpn/network.sh \
    etc/init.d/flowvpn \
    www/cgi-bin/flowvpn \
| ssh "$ROUTER" 'cd / && tar x'

cat www/flowvpn/index.html | ssh "$ROUTER" 'cat > /www/eclipvpn/index.html'

echo "→ install dependencies + xray + Tailscale on router"
ssh "$ROUTER" "WITH_REMOTE=$WITH_REMOTE sh -s" <<'REMOTE_EOF'
set -eu

echo "[1/5] opkg deps"
opkg update >/dev/null 2>&1 || true
opkg install jq coreutils-base64 kmod-nft-tproxy sing-box unzip 2>&1 | grep -E "Installing|installed" || true

echo "[2/5] xray 26.4.17"
ARCH=$(uname -m)
case "$ARCH" in
    aarch64) XRAY_ARCH="arm64-v8a" ;;
    armv7l)  XRAY_ARCH="arm32-v7a" ;;
    x86_64)  XRAY_ARCH="64" ;;
    *)       echo "ERROR: unsupported arch $ARCH"; exit 1 ;;
esac
cd /tmp
wget -q "https://github.com/XTLS/Xray-core/releases/download/v26.4.17/Xray-linux-${XRAY_ARCH}.zip" -O xray.zip
unzip -o xray.zip xray -d /tmp/ >/dev/null
cp /tmp/xray /usr/bin/xray
chmod +x /usr/bin/xray
rm -f /tmp/xray.zip /tmp/xray
echo "  installed: $(/usr/bin/xray version 2>&1 | head -1)"

echo "[3/5] permissions + initial config"
chmod +x /usr/bin/flowvpn /etc/init.d/flowvpn /www/cgi-bin/flowvpn /usr/lib/flowvpn/*.sh
/usr/bin/flowvpn >/dev/null 2>&1 || true  # creates default config

# legacy /flowvpn/ → /eclipvpn/ redirect for old bookmarks
cat > /www/flowvpn/index.html <<'HTML'
<!DOCTYPE html>
<meta charset="utf-8">
<meta http-equiv="refresh" content="0;url=/eclipvpn/">
<title>EclipVPN</title>
<p>Адрес изменился. Открываю <a href="/eclipvpn/">/eclipvpn/</a>…</p>
HTML

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
/etc/init.d/flowvpn enable

echo
echo "===== INSTALL DONE ====="
echo "next steps (Mac side):"
echo "  1) on first router: ssh root@192.168.1.1 'flowvpn backup' > ~/eclip-config.json"
echo "  2) on this router:  scp ~/eclip-config.json root@$(uci -q get network.lan.ipaddr || echo 192.168.2.1):/tmp/"
echo "                       ssh root@... 'flowvpn restore < /tmp/eclip-config.json'"
REMOTE_EOF

echo
echo "✓ install done — UI at http://${ROUTER#*@}/eclipvpn/"
echo "  если выше есть TAILSCALE_AUTH_URL — открой его в браузере и подставь свежий Device Auth Key"
