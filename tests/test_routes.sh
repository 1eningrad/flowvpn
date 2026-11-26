# test_routes.sh — all_vpn route rules: RustDesk ports go direct, full_tunnel keeps them on the VPN.
_rt_rule='[.[] | select(.port_range == ["21114:21119"])]'
_rt_dir() { SR_RULES_DIR="$ECLIPVPN_TMP/rules"; mkdir -p "$SR_RULES_DIR"; CUSTOM_DIRECT="$ECLIPVPN_TMP/none.txt"; }

_t routes_rustdesk_direct
_rt_dir; fresh_config '{"mode":"all_vpn"}'
rules=""; dns_rules=""; _build_allvpn_rules
assert_json "valid-json"     "$rules" 'type' array
assert_json "rustdesk-rule"  "$rules" "$_rt_rule | length" 1
assert_json "rustdesk-direct" "$rules" "$_rt_rule | .[0].outbound" direct
assert_json "before-ru"      "$rules" "(map(.port_range != null) | index(true)) < (map(.rule_set != null) | index(true))" true

_t routes_rustdesk_full_tunnel
_rt_dir; fresh_config '{"mode":"all_vpn","full_tunnel":true}'
rules=""; dns_rules=""; _build_allvpn_rules
assert_json "ft-valid-json"  "$rules" 'type' array
assert_json "ft-no-rustdesk" "$rules" "$_rt_rule | length" 0
