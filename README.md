# FlowVPN

Lightweight VPN manager for OpenWrt routers. Routes all traffic through VPN (VLESS+XHTTP+Reality), Russian sites go direct.

## Features

- **Two routing modes**: All VPN (except RU) / Blocklist only
- **VLESS+XHTTP+Reality** via xray-core 26.4.17+
- **sing-box** tproxy routing with geosite-ru/geoip-ru
- **DNS protection**: hijacks DNS, blocks DoT/QUIC to prevent ISP poisoning
- **Web UI**: dark/light theme, Russian interface
- **Server management**: subscription import, ping, manual selection
- **Per-device routing**: VPN or Direct per device
- **Real-time speed**: via Clash API WebSocket
- **Auto-failover**: watchdog switches server on failure
- **Diagnostics**: 25 automated health checks
- **Logs**: three sources (FlowVPN/sing-box/xray), filters, export
- **Schedule**: cron-based on/off
- **Backup/restore**: JSON export/import

## Requirements

- OpenWrt router (tested on Routerich AX3000, aarch64)
- 256MB+ RAM, 40MB+ free flash
- Internet access for downloading xray and rule sets

## Quick Install

```bash
ssh root@your-router
curl -sSL https://raw.githubusercontent.com/1eningrad/flowvpn/main/install.sh | sh
```

## Manual Install

```bash
# 1. Install dependencies
opkg update
opkg install jq coreutils-base64 kmod-nft-tproxy sing-box

# 2. Install xray 26.4.17+ (NOT from opkg — too old)
# Download from https://github.com/XTLS/Xray-core/releases
# Upload to /usr/bin/xray

# 3. Copy FlowVPN files
# usr/bin/flowvpn           → /usr/bin/flowvpn
# usr/lib/flowvpn/          → /usr/lib/flowvpn/
# www/cgi-bin/flowvpn       → /www/cgi-bin/flowvpn
# www/flowvpn/index.html    → /www/flowvpn/index.html
# etc/init.d/flowvpn        → /etc/init.d/flowvpn

# 4. Set permissions
chmod +x /usr/bin/flowvpn /www/cgi-bin/flowvpn /etc/init.d/flowvpn /usr/lib/flowvpn/*.sh

# 5. Configure
flowvpn set-config subscription_url "https://your-subscription-url"
flowvpn update
flowvpn start

# 6. Enable autostart
/etc/init.d/flowvpn enable
```

## Web UI

Open `http://router-ip/flowvpn/` in browser.

## CLI Usage

```bash
flowvpn start|stop|restart|status
flowvpn set-server N              # Select server by index
flowvpn set-mode all_vpn|blocklist
flowvpn update                    # Update subscription + rules
flowvpn ping                      # Ping all servers
flowvpn diagnose                  # Quick diagnostics
flowvpn healthcheck               # Full 25-point health check
flowvpn add-domain DOMAIN vpn     # Force domain through VPN
flowvpn add-domain DOMAIN direct  # Force domain direct
flowvpn get-log 50 all            # View logs
flowvpn backup                    # Export settings
```

## Architecture

```
Client → dnsmasq(:53) → sing-box DNS(:5354) → dns-proxy(VPN) / dns-direct
       → nftables tproxy → sing-box(:2154) → xray SOCKS(:1080) → VPN server
                                            → direct (RU sites)
```

## Important Notes

- **xray must be 26.4.17+** — opkg version (25.1.30) has critical XHTTP bugs
- **Mark 0x8000 (32768)** — required for fw4 firewall bypass
- **geosite-ru includes google.com** — Google AI services (Gemini) need to be added to force-VPN list
- **QUIC (UDP 443) is blocked** in all_vpn mode — apps fall back to TCP

## License

MIT
