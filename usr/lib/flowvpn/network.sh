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
                    # Resolve hostname to IP
                    local resolved=$(nslookup "$host" 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}')
                    [ -n "$resolved" ] && nft add rule ip flowvpn prerouting ip daddr "$resolved" return 2>/dev/null
                    ;;
            esac
        done
    fi

    # Per-device direct rules (bypass VPN)
    if [ -f "$FLOWVPN_CONFIG" ]; then
        for dev_ip in $(jq -r '.device_rules // {} | to_entries[] | select(.value == "direct") | .key' "$FLOWVPN_CONFIG" 2>/dev/null); do
            nft add rule ip flowvpn prerouting ip saddr "$dev_ip" return 2>/dev/null
        done
    fi

    # Detect LAN subnet from interface
    local lan_subnet=$(ip -4 addr show "$iface" 2>/dev/null | grep -oE 'inet [0-9./]+' | awk '{print $2}')
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
