# test_switch.sh — make-before-break switch helpers (port arithmetic).
# Sourced by tests/run.sh against the real functions in usr/bin/eclipvpn.

# --- _stage_xray_port: which alternate port to stage the NEW xray on ---------
_t "stage_port: xray active 1080 -> stage 1081"
assert_eq "x1080" "$(_stage_xray_port 1080 xray)" "1081"
_t "stage_port: xray active 1081 -> stage 1080"
assert_eq "x1081" "$(_stage_xray_port 1081 xray)" "1080"
_t "stage_port: old hysteria2 owns 1080 -> always stage 1081"
assert_eq "hy1080" "$(_stage_xray_port 1080 singbox)" "1081"
assert_eq "hy1081" "$(_stage_xray_port 1081 singbox)" "1081"

# --- _active_xray_port: state file with 1080 default -------------------------
_t "active_xray_port: absent -> 1080"
rm -f "$ECLIPVPN_TMP/xray_port"
assert_eq "noport" "$(_active_xray_port)" "1080"
_t "active_xray_port: file value wins"
echo 1081 > "$ECLIPVPN_TMP/xray_port"
assert_eq "port1081" "$(_active_xray_port)" "1081"
rm -f "$ECLIPVPN_TMP/xray_port"

# --- _active_socks_port: engine-aware -----------------------------------------
printf '%s' '[{"protocol":"vless","host":"h","port":443},{"protocol":"hysteria2","host":"h2","port":443}]' > "$ECLIPVPN_TMP/servers.json"
_t "active_socks_port: xray engine -> the active xray port"
fresh_config '{"selected_server":0}'
echo 1081 > "$ECLIPVPN_TMP/xray_port"
assert_eq "socks_xray" "$(_active_socks_port)" "1081"
_t "active_socks_port: hysteria2 engine -> 1080 (sing-box owns it), ignores xray_port"
fresh_config '{"selected_server":1}'
assert_eq "socks_hy2" "$(_active_socks_port)" "1080"
rm -f "$ECLIPVPN_TMP/xray_port" "$ECLIPVPN_TMP/servers.json"
