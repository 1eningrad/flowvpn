#!/bin/ash
# EclipVPN v4 — nftables TPROXY + per-device routing
# Uses 'ip' table (not inet) for tproxy
# tproxy mark 0x1, sing-box mark 0x8000

ECLIPVPN_CONFIG="/etc/eclipvpn/config.json"

setup_network() {
    local port="$1" mark="$2" iface="$3"

    # Clean up
    nft delete table ip eclipvpn 2>/dev/null
    nft delete table inet eclipvpn 2>/dev/null
    nft delete table ip eclipvpn_dns 2>/dev/null
    ip rule del fwmark 0x1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null

    # Policy routing
    ip rule add fwmark 0x1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # Create table and chain
    nft add table ip eclipvpn
    nft add chain ip eclipvpn prerouting '{ type filter hook prerouting priority mangle; policy accept; }'

    # Anti-loop: skip sing-box/xray marked traffic
    nft add rule ip eclipvpn prerouting meta mark 0x00008000 return

    # Skip private/local
    nft add rule ip eclipvpn prerouting ip daddr 10.0.0.0/8 return
    nft add rule ip eclipvpn prerouting ip daddr 127.0.0.0/8 return
    nft add rule ip eclipvpn prerouting ip daddr 172.16.0.0/12 return
    nft add rule ip eclipvpn prerouting ip daddr 192.168.0.0/16 return
    nft add rule ip eclipvpn prerouting ip daddr 224.0.0.0/4 return
    nft add rule ip eclipvpn prerouting ip daddr 255.255.255.255 return

    # Skip VPN server IPs (resolve hostnames to IPs first)
    if [ -f /tmp/eclipvpn/servers.json ]; then
        for host in $(jq -r '.[].host' /tmp/eclipvpn/servers.json 2>/dev/null | sort -u); do
            # Check if it's already an IP or hostname
            case "$host" in
                [0-9]*.*)
                    nft add rule ip eclipvpn prerouting ip daddr "$host" return 2>/dev/null
                    ;;
                *)
                    # Resolve hostname to IPv4 only — busybox nslookup also
                    # returns the resolver's own address and any IPv6 records.
                    # Adding an IPv6 to an `ip` (v4) table fails silently and
                    # leaves the VPN server without a bypass rule, so the
                    # outbound connection ends up tproxied to itself (loop).
                    local resolved
                    resolved=$(nslookup "$host" 2>/dev/null | awk '/^Address/{print $NF}' | \
                               grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^127\.' | tail -1)
                    [ -n "$resolved" ] && nft add rule ip eclipvpn prerouting ip daddr "$resolved" return 2>/dev/null
                    ;;
            esac
        done
    fi

    # Per-device direct rules (bypass VPN). Keys can be either:
    # - IPv4 address (e.g. "192.168.1.50") — matches by source IP
    # - MAC address (e.g. "AA:BB:CC:DD:EE:FF") — matches by source MAC
    # MAC is preferred since DHCP can hand a different IP across reboots.
    if [ -f "$ECLIPVPN_CONFIG" ]; then
        for dev_key in $(jq -r '.device_rules // {} | to_entries[] | select(.value == "direct") | .key' "$ECLIPVPN_CONFIG" 2>/dev/null); do
            case "$dev_key" in
                [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:*)
                    # ether saddr in `ip` table requires the packet to enter
                    # via a bridge port. Works for br-lan but fails on VLAN /
                    # PPPoE setups — log so the user knows when it doesn't.
                    if ! nft add rule ip eclipvpn prerouting ether saddr "$dev_key" return 2>/tmp/eclipvpn/nft_err; then
                        logger -t eclipvpn "WARN: failed to add MAC rule for $dev_key — $(cat /tmp/eclipvpn/nft_err 2>/dev/null | head -1)"
                    fi
                    rm -f /tmp/eclipvpn/nft_err
                    ;;
                [0-9]*.[0-9]*.[0-9]*.[0-9]*)
                    nft add rule ip eclipvpn prerouting ip saddr "$dev_key" return 2>/dev/null
                    ;;
            esac
        done
    fi

    # Detect LAN subnet from interface. NR==1 — alias interfaces and
    # secondary IPv4s would otherwise concat into a multi-line string,
    # the unquoted expansion below splits it into multiple nft args, and
    # the rule silently fails to install (LAN never gets tproxied).
    local lan_subnet
    lan_subnet=$(ip -4 addr show "$iface" 2>/dev/null | grep -oE 'inet [0-9./]+' | awk 'NR==1{print $2; exit}')
    if [ -z "$lan_subnet" ]; then
        lan_subnet="192.168.1.0/24"
        logger -t eclipvpn "WARN: could not detect LAN subnet on $iface — using fallback $lan_subnet; if the real LAN differs, clients are NOT tproxied (direct leak)"
    fi

    # TPROXY: LAN clients → sing-box
    nft add rule ip eclipvpn prerouting ip saddr "$lan_subnet" meta l4proto tcp tproxy to :$port meta mark set 0x1 counter accept
    nft add rule ip eclipvpn prerouting ip saddr "$lan_subnet" meta l4proto udp tproxy to :$port meta mark set 0x1 counter accept

    # DNS redirect: dnsmasq → sing-box
    _setup_dnsmasq_redirect

    # IPv6 kill-switch — everything above is IPv4-only; close the v6 leak.
    _ipv6_killswitch_on "$iface"
}

# DNS-redirect drop-in for OpenWrt's dnsmasq. We write to /tmp/dnsmasq.d/
# (which the default OpenWrt dnsmasq.conf includes via conf-dir) instead of
# committing to /etc/config/dhcp because:
#
#  1. Power-yank survival. uci commit is persistent — after a hard reboot,
#     dnsmasq came up with `server=127.0.0.1#5354` pointing at a sing-box
#     that hasn't started yet. DNS resolution failed for everything
#     including the subscription URL, so cmd_start couldn't fetch servers
#     and the VPN never came up. /tmp wipes on reboot → bad state can't
#     persist past a power loss.
#  2. /etc/config/dhcp churn. uci writes can race with LuCI/Tailscale and
#     leave the file partly-rewritten.
DNSMASQ_REDIRECT_CONF="/tmp/dnsmasq.d/eclipvpn.conf"

_setup_dnsmasq_redirect() {
    _clean_legacy_dnsmasq_uci
    mkdir -p /tmp/dnsmasq.d
    cat > "$DNSMASQ_REDIRECT_CONF" <<EOF
no-resolv
server=127.0.0.1#5354
cache-size=0
EOF
    /etc/init.d/dnsmasq restart
}

_restore_dnsmasq() {
    rm -f "$DNSMASQ_REDIRECT_CONF"
    _clean_legacy_dnsmasq_uci
    /etc/init.d/dnsmasq restart
}

# Migration: pre-fix versions persisted the redirect via uci commit dhcp.
# Routers that ran old code keep that state across upgrade — strip it on
# every setup/teardown so old installs self-heal on first start, and after
# a full uninstall the user's dnsmasq is left clean.
_clean_legacy_dnsmasq_uci() {
    local servers
    servers=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)
    case " $servers " in
        *" 127.0.0.1#5354 "*|*"127.0.0.1#5354"*)
            uci delete dhcp.@dnsmasq[0].server 2>/dev/null
            uci delete dhcp.@dnsmasq[0].noresolv 2>/dev/null
            uci delete dhcp.@dnsmasq[0].cachesize 2>/dev/null
            uci commit dhcp
            ;;
    esac
    rm -f /tmp/eclipvpn/dnsmasq_backup
}

# Safe to call before any subscription fetch on cmd_start: undoes a stale
# committed redirect (left by an upgraded-from-old-code install or by a
# crashed uninstall) so /etc/resolv.conf → dnsmasq actually resolves.
ensure_dns_sane() {
    local servers
    servers=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)
    case " $servers " in
        *"127.0.0.1#5354"*)
            _clean_legacy_dnsmasq_uci
            /etc/init.d/dnsmasq restart >/dev/null 2>&1
            sleep 1
            ;;
    esac
}

teardown_network() {
    nft delete table ip eclipvpn 2>/dev/null
    nft delete table inet eclipvpn 2>/dev/null
    nft delete table ip eclipvpn_dns 2>/dev/null
    ip rule del fwmark 0x1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    _ipv6_killswitch_off
    _restore_dnsmasq
}

# IPv6 kill-switch. The tproxy/route/DNS stack above is IPv4-only; on a
# dual-stack WAN, LAN clients would route IPv6 straight out the WAN — past
# the tunnel (real-IP + DNS leak) and past the QUIC/DoT rejects. We do not
# tunnel IPv6, so fail CLOSED: disable IPv6 on the LAN bridge while the VPN
# is up, saving the prior value and restoring it on teardown. State lives in
# /tmp so a power-yank can't strand IPv6 disabled. cmd_restart is soft and
# keeps the switch in place across the process swap; only cmd_stop restores.
_ipv6_killswitch_on() {
    local ifc="$1"
    local p="/proc/sys/net/ipv6/conf/$ifc/disable_ipv6"
    [ -w "$p" ] || { logger -t eclipvpn "WARN: $p not writable — IPv6 may leak around the tunnel"; return 0; }
    if [ ! -f /tmp/eclipvpn/ipv6_disable.iface ]; then
        cat "$p" > /tmp/eclipvpn/ipv6_disable.saved 2>/dev/null
        echo "$ifc" > /tmp/eclipvpn/ipv6_disable.iface 2>/dev/null
    fi
    echo 1 > "$p" 2>/dev/null
    logger -t eclipvpn "IPv6 kill-switch: disabled IPv6 on $ifc (fail closed; no v6 tunneling)"
}
_ipv6_killswitch_off() {
    local f=/tmp/eclipvpn/ipv6_disable.iface ifc p saved
    [ -f "$f" ] || return 0
    ifc=$(cat "$f" 2>/dev/null)
    p="/proc/sys/net/ipv6/conf/$ifc/disable_ipv6"
    saved=$(cat /tmp/eclipvpn/ipv6_disable.saved 2>/dev/null)
    [ -z "$saved" ] && saved=0
    [ -w "$p" ] && echo "$saved" > "$p" 2>/dev/null
    rm -f "$f" /tmp/eclipvpn/ipv6_disable.saved
    logger -t eclipvpn "IPv6 kill-switch: restored IPv6 on ${ifc:-LAN}"
}
