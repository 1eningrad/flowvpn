#!/bin/ash
# FlowVPN v4 — nftables TPROXY + per-device routing
# Uses 'ip' table (not inet) for tproxy
# tproxy mark 0x1, sing-box mark 0x8000

FLOWVPN_CONFIG="/etc/flowvpn/config.json"

setup_network() {
    local port="$1" mark="$2" iface="$3"

    # Clean up
    nft delete table ip flowvpn 2>/dev/null
    nft delete table inet flowvpn 2>/dev/null
    nft delete table ip flowvpn_dns 2>/dev/null
    ip rule del fwmark 0x1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null

    # Policy routing
    ip rule add fwmark 0x1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100

    # Create table and chain
    nft add table ip flowvpn
    nft add chain ip flowvpn prerouting '{ type filter hook prerouting priority mangle; policy accept; }'

    # Anti-loop: skip sing-box/xray marked traffic
    nft add rule ip flowvpn prerouting meta mark 0x00008000 return

    # Skip private/local
    nft add rule ip flowvpn prerouting ip daddr 10.0.0.0/8 return
    nft add rule ip flowvpn prerouting ip daddr 127.0.0.0/8 return
    nft add rule ip flowvpn prerouting ip daddr 172.16.0.0/12 return
    nft add rule ip flowvpn prerouting ip daddr 192.168.0.0/16 return
    nft add rule ip flowvpn prerouting ip daddr 224.0.0.0/4 return
    nft add rule ip flowvpn prerouting ip daddr 255.255.255.255 return

    # Skip VPN server IPs (resolve hostnames to IPs first)
    if [ -f /tmp/flowvpn/servers.json ]; then
        for host in $(jq -r '.[].host' /tmp/flowvpn/servers.json 2>/dev/null | sort -u); do
            # Check if it's already an IP or hostname
            case "$host" in
                [0-9]*.*)
                    nft add rule ip flowvpn prerouting ip daddr "$host" return 2>/dev/null
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
                    [ -n "$resolved" ] && nft add rule ip flowvpn prerouting ip daddr "$resolved" return 2>/dev/null
                    ;;
            esac
        done
    fi

    # Per-device direct rules (bypass VPN). Keys can be either:
    # - IPv4 address (e.g. "192.168.1.50") — matches by source IP
    # - MAC address (e.g. "AA:BB:CC:DD:EE:FF") — matches by source MAC
    # MAC is preferred since DHCP can hand a different IP across reboots.
    if [ -f "$FLOWVPN_CONFIG" ]; then
        for dev_key in $(jq -r '.device_rules // {} | to_entries[] | select(.value == "direct") | .key' "$FLOWVPN_CONFIG" 2>/dev/null); do
            case "$dev_key" in
                [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:*)
                    # ether saddr in `ip` table requires the packet to enter
                    # via a bridge port. Works for br-lan but fails on VLAN /
                    # PPPoE setups — log so the user knows when it doesn't.
                    if ! nft add rule ip flowvpn prerouting ether saddr "$dev_key" return 2>/tmp/flowvpn/nft_err; then
                        logger -t flowvpn "WARN: failed to add MAC rule for $dev_key — $(cat /tmp/flowvpn/nft_err 2>/dev/null | head -1)"
                    fi
                    rm -f /tmp/flowvpn/nft_err
                    ;;
                [0-9]*.[0-9]*.[0-9]*.[0-9]*)
                    nft add rule ip flowvpn prerouting ip saddr "$dev_key" return 2>/dev/null
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
    [ -z "$lan_subnet" ] && lan_subnet="192.168.1.0/24"

    # TPROXY: LAN clients → sing-box
    nft add rule ip flowvpn prerouting ip saddr "$lan_subnet" meta l4proto tcp tproxy to :$port meta mark set 0x1 counter accept
    nft add rule ip flowvpn prerouting ip saddr "$lan_subnet" meta l4proto udp tproxy to :$port meta mark set 0x1 counter accept

    # DNS redirect: dnsmasq → sing-box
    _setup_dnsmasq_redirect
}

_setup_dnsmasq_redirect() {
    if [ ! -f /tmp/flowvpn/dnsmasq_backup ]; then
        uci show dhcp.@dnsmasq[0] > /tmp/flowvpn/dnsmasq_backup 2>/dev/null
    fi
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5354'
    uci set dhcp.@dnsmasq[0].cachesize='0'
    uci commit dhcp
    /etc/init.d/dnsmasq restart
}

_restore_dnsmasq() {
    if [ -f /tmp/flowvpn/dnsmasq_backup ]; then
        uci delete dhcp.@dnsmasq[0].server 2>/dev/null
        uci set dhcp.@dnsmasq[0].noresolv='0'
        uci delete dhcp.@dnsmasq[0].cachesize 2>/dev/null
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        rm -f /tmp/flowvpn/dnsmasq_backup
    fi
}

teardown_network() {
    nft delete table ip flowvpn 2>/dev/null
    nft delete table inet flowvpn 2>/dev/null
    nft delete table ip flowvpn_dns 2>/dev/null
    ip rule del fwmark 0x1 table 100 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null
    _restore_dnsmasq
}
