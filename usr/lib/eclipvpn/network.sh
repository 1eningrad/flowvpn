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
    nft add rule ip eclipvpn prerouting ip daddr 169.254.0.0/16 return
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

    # Cap WAN egress MTU so xray's (router-originated, unclamped) outbound
    # frames fit PMTU-blackhole uplinks. No-op on clean 1500 paths past the
    # idempotent check; configurable via wan_mtu (0 = leave interface alone).
    _apply_wan_mtu
}

# DNS redirect: point dnsmasq at sing-box's DNS (:5354) for ALL LAN queries.
#
# Set via uci (/etc/config/dhcp), NOT a /tmp/dnsmasq.d drop-in. The drop-in
# approach silently failed on current OpenWrt (25.x): dnsmasq uses a
# PER-INSTANCE conf-dir (/tmp/dnsmasq.cfgXXXX.d), so a static
# /tmp/dnsmasq.d/eclipvpn.conf is never read. dnsmasq then falls back to the
# ISP resolver — which NXDOMAINs censored domains (youtube.com etc.) and
# bypasses sing-box's split-DNS entirely, i.e. a silent DNS leak. Observed
# live: only the box using the router's DNS (a PC) failed; phones with their
# own DoH/Private DNS worked, masking the bug.
#
# The original reason for avoiding uci was boot-safety — a persisted
# server=127.0.0.1#5354 pointing at a not-yet-started sing-box wedged the
# subscription fetch on reboot. That is handled by ensure_dns_sane(), called
# at the top of cmd_start, which strips this redirect before any fetch so the
# router resolves normally until sing-box is up and the redirect is re-added.
DNSMASQ_REDIRECT_CONF="/tmp/dnsmasq.d/eclipvpn.conf"

_setup_dnsmasq_redirect() {
    _clean_legacy_dnsmasq_uci
    rm -f "$DNSMASQ_REDIRECT_CONF"               # drop any stale drop-in from older code
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5354'
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci set dhcp.@dnsmasq[0].cachesize='0'
    uci commit dhcp
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
            # del_list removes ONLY our redirect entry. A plain
            # `uci delete ...server` nukes the entire list, destroying any
            # upstream DNS the user configured via LuCI (e.g. 8.8.8.8). The
            # noresolv/cachesize options were ours, so revert them to defaults.
            uci del_list dhcp.@dnsmasq[0].server='127.0.0.1#5354' 2>/dev/null
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
    _restore_wan_mtu
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

# WAN MTU guard for PMTU-blackhole uplinks.
#
# Some uplinks (CGNAT, PPPoE, double-NAT, certain wired ISPs) have a path MTU
# below 1500 AND silently drop oversized DF packets while filtering the ICMP
# "fragmentation needed" reply — a classic PMTUD black hole. The symptom is
# brutal and VPN-specific: pings/DNS/small requests fly, but the tunnel crawls
# or dies. Why VPN-specific: xray's connection to the VPN server is
# router-ORIGINATED, so the firewall's `mtu_fix` MSS clamp (which only touches
# FORWARDED LAN traffic) never bounds it; xray happily emits 1500-byte frames
# that vanish into the black hole. On a clean uplink (e.g. LTE) the same setup
# works perfectly — which is exactly the "works on LTE, dies on the wired line"
# report that pinned this down.
#
# Empirically (tested live, same server, back-to-back) the ONLY mechanism that
# fixes it is lowering the WAN *interface* MTU — a device-level hard cap on
# egress frame size. A per-route `mtu`, an nft `tcp option maxseg size set`
# clamp, and xray's `sockopt.tcpMaxSeg` were ALL tried and ALL failed to bound
# what we transmit on the affected uplink; only the interface MTU did. 1400 is
# the conventional tunnel-safe value (~1% overhead on a clean 1500 path, i.e.
# harmless on LTE). Tunable via config `wan_mtu`; set it to 0 to leave the
# interface untouched. Mirrors the IPv6 kill-switch save/restore: original MTU
# saved in /tmp, restored only on full cmd_stop (soft restart keeps it).
_wan_default_dev() {
    ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
_apply_wan_mtu() {
    local target
    target=$(get_config_val wan_mtu 1400)
    case "$target" in ''|*[!0-9]*) target=1400 ;; esac
    [ "$target" -eq 0 ] && return 0
    local dev; dev=$(_wan_default_dev)
    [ -z "$dev" ] && { logger -t eclipvpn "WARN: wan_mtu: no default-route device"; return 0; }
    local cur; cur=$(cat "/sys/class/net/$dev/mtu" 2>/dev/null)
    [ "$cur" = "$target" ] && return 0       # already applied — idempotent, cheap to re-call
    # Remember the pre-eclipvpn MTU once, so teardown can put it back.
    [ -f /tmp/eclipvpn/wan_mtu.orig ] || echo "${cur:-1500}" > /tmp/eclipvpn/wan_mtu.orig
    if ip link set "$dev" mtu "$target" 2>/dev/null; then
        logger -t eclipvpn "wan_mtu: $dev MTU ${cur:-?} → $target (PMTU-blackhole guard)"
    else
        logger -t eclipvpn "WARN: wan_mtu: failed to set $dev MTU $target"
    fi
}
_restore_wan_mtu() {
    local orig; orig=$(cat /tmp/eclipvpn/wan_mtu.orig 2>/dev/null)
    [ -z "$orig" ] && return 0
    local dev; dev=$(_wan_default_dev)
    [ -n "$dev" ] && ip link set "$dev" mtu "$orig" 2>/dev/null \
        && logger -t eclipvpn "wan_mtu: restored $dev MTU → $orig"
    rm -f /tmp/eclipvpn/wan_mtu.orig
}
