# test_validators.sh — input validators + engine helpers. Sourced by run.sh.

# --- _validate_ipv4 (config.sh) ---
_t validate_ipv4
_validate_ipv4 '1.2.3.4';         assert_rc "ipv4-ok"        "$?" 0
_validate_ipv4 '255.255.255.255'; assert_rc "ipv4-max"       "$?" 0
_validate_ipv4 '256.1.1.1';       assert_rc "ipv4-octet>255" "$?" 1
_validate_ipv4 '1.2.3';           assert_rc "ipv4-short"     "$?" 1
_validate_ipv4 '1.2.3.4.5';       assert_rc "ipv4-long"      "$?" 1
_validate_ipv4 'a.b.c.d';         assert_rc "ipv4-nondigit"  "$?" 1
_validate_ipv4 '192.168.0.0/24';  assert_rc "ipv4-cidr-rej"  "$?" 1

# --- _normalize_mac (config.sh) — normalises to uppercase, rejects junk ---
_t normalize_mac
assert_eq "mac-upper" "$(_normalize_mac 'aa:bb:cc:dd:ee:ff')" 'AA:BB:CC:DD:EE:FF'
_normalize_mac 'not-a-mac' >/dev/null 2>&1; assert_rc "mac-rej" "$?" 1

# --- _engine_for_protocol (core) ---
_t engine_for_protocol
assert_eq "eng-hy2"   "$(_engine_for_protocol hysteria2)" singbox
assert_eq "eng-vless" "$(_engine_for_protocol vless)"     xray
assert_eq "eng-empty" "$(_engine_for_protocol '')"        xray
assert_eq "eng-trojan" "$(_engine_for_protocol trojan)"   xray

# --- _is_metered_server (core) — RU mobile exits skipped, CDN "Обход" not ---
_t is_metered
_is_metered_server 'МТС Москва';   assert_rc "metered-mts"      "$?" 0
_is_metered_server 'Обход МТС';    assert_rc "metered-cdn-not"  "$?" 1
_is_metered_server '🇸🇪 Швеция';    assert_rc "metered-foreign"  "$?" 1
_is_metered_server 'Билайн LTE';   assert_rc "metered-beeline"  "$?" 0

# --- _server_protocol (core) reads servers.json[$idx].protocol // "vless" ---
_t server_protocol
printf '%s' '[{"protocol":"vless","host":"a"},{"protocol":"hysteria2","host":"b"},{"host":"c"}]' \
    > "$ECLIPVPN_TMP/servers.json"
assert_eq "sp-idx0-vless"   "$(_server_protocol 0)" vless
assert_eq "sp-idx1-hy2"     "$(_server_protocol 1)" hysteria2
assert_eq "sp-idx2-default" "$(_server_protocol 2)" vless
rm -f "$ECLIPVPN_TMP/servers.json"
