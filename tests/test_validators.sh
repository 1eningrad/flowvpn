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

# --- _name_has_token (core) — the muted_servers matcher ---
# Pure substring matching over a comma-separated list; MUST stay glob-free (the
# token is quoted inside the case pattern) so a name or token containing * or ?
# can't turn into a wildcard match.
_t name_has_token
_name_has_token 'Обход МТС'  'Обход';            assert_rc "tok-hit"        "$?" 0
_name_has_token '🇸🇪 Швеция'  'Обход';            assert_rc "tok-miss"       "$?" 1
_name_has_token 'Обход МТС'  '';                 assert_rc "tok-empty-list" "$?" 1
_name_has_token '🇩🇪 Германия' 'Обход,Германия';  assert_rc "tok-second"     "$?" 0
_name_has_token 'Обход'      'Обход,,';          assert_rc "tok-blank-skip" "$?" 0
_name_has_token 'ЛЮБОЙ'      '*';                assert_rc "tok-no-glob"    "$?" 1
_name_has_token 'a?b'        'a?b';              assert_rc "tok-literal-q"  "$?" 0
_name_has_token 'обход'      'Обход';            assert_rc "tok-case-sens"  "$?" 1

# --- _is_auto_skipped (core) — metered OR muted, used by every auto picker ---
# The two skips are NOT interchangeable: metered is a correctness skip that the
# emergency pass must never lift, muted is a cost skip that it does lift.
_t is_auto_skipped
_is_auto_skipped 'Обход МТС'  'Обход'; assert_rc "skip-muted"        "$?" 0
_is_auto_skipped 'Обход МТС'  '';      assert_rc "skip-cdn-default"  "$?" 1
_is_auto_skipped 'МТС Москва' '';      assert_rc "skip-metered"      "$?" 0
_is_auto_skipped '🇸🇪 Швеция'  'Обход'; assert_rc "skip-free"         "$?" 1
_is_auto_skipped '🇸🇪 Швеция'  'Швеция';assert_rc "skip-any-muted"    "$?" 0

# --- mute list round-trip (servers.sh) — mute/unmute rewrite muted_servers ---
_t mute_roundtrip
printf '%s' '{"selected_server":0}' > "$ECLIPVPN_CONFIG"
printf '%s' '[{"name":"🇸🇪 Швеция","host":"a"},{"name":"Обход МТС","host":"b"},{"name":"Обход Т2","host":"c"}]' \
    > "$ECLIPVPN_TMP/servers.json"
assert_json "mute-status"  "$(cmd_mute_server 1)"   '.status'       muted
assert_eq   "mute-stored"  "$(get_config_val muted_servers '')"     'Обход МТС'
# One token matches only its own server here — the count comes from the pool.
assert_json "mute-count"   "$(cmd_mute_server 1)"   '.muted_count'  1
assert_json "mute-again"   "$(cmd_mute_server 1)"   '.status'       unchanged
# A second, unrelated mute appends rather than replaces.
assert_json "mute-2nd"     "$(cmd_mute_server 0)"   '.status'       muted
assert_eq   "mute-list-2"  "$(get_config_val muted_servers '')"     'Обход МТС,🇸🇪 Швеция'
# Unmute drops every token the name matches and leaves the others alone.
assert_json "unmute"       "$(cmd_unmute_server 1)" '.status'       unmuted
assert_eq   "unmute-left"  "$(get_config_val muted_servers '')"     '🇸🇪 Швеция'
assert_json "unmute-again" "$(cmd_unmute_server 1)" '.status'       unchanged
# Family token: muting via a shared substring covers siblings, and un-muting one
# sibling removes the family token (and says so in removed_tokens).
cmd_set_config muted_servers 'Обход' >/dev/null 2>&1
assert_json "family-count" "$(cmd_mute_server 1)"   '.muted_count'  2
assert_json "family-rm"    "$(cmd_unmute_server 2)" '.removed_tokens[0]' 'Обход'
assert_eq   "family-clear" "$(get_config_val muted_servers '')"     ''
# Bounds + junk indices must fail, not silently mute server 0.
cmd_mute_server 9 >/dev/null 2>&1;   assert_rc "mute-oob"  "$?" 1
cmd_mute_server 'x' >/dev/null 2>&1; assert_rc "mute-junk" "$?" 1
# ...and the failure must reach the WIRE as JSON. _err prints to stdout and the
# name resolver runs in a command substitution, so an un-re-emitted error would
# leave the CGI with an empty body — the UI would lose the reason entirely.
assert_json "mute-oob-json"    "$(cmd_mute_server 9 2>/dev/null)"     '.error|length>0' true
assert_json "unmute-junk-json" "$(cmd_unmute_server 'x' 2>/dev/null)" '.error|length>0' true
rm -f "$ECLIPVPN_TMP/servers.json"

# --- _server_protocol (core) reads servers.json[$idx].protocol // "vless" ---
_t server_protocol
printf '%s' '[{"protocol":"vless","host":"a"},{"protocol":"hysteria2","host":"b"},{"host":"c"}]' \
    > "$ECLIPVPN_TMP/servers.json"
assert_eq "sp-idx0-vless"   "$(_server_protocol 0)" vless
assert_eq "sp-idx1-hy2"     "$(_server_protocol 1)" hysteria2
assert_eq "sp-idx2-default" "$(_server_protocol 2)" vless
rm -f "$ECLIPVPN_TMP/servers.json"
