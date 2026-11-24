# test_outage.sh — one journal record per outage: opened, closed in place, folded.
OJ="$ECLIPVPN_TMP/incidents.json"; OM="$ECLIPVPN_TMP/outage"
fresh_config '{"selected_server":0,"running_intent":true}'
printf '%s' '[{"name":"UZ x","host":"uz"},{"name":"NL","host":"nl"}]' > "$ECLIPVPN_TMP/servers.json"
_o_reset() { echo '[]' > "$OJ"; rm -f "$OM" "$ECLIPVPN_TMP"/wan_down_* "$ECLIPVPN_TMP/op.in_progress"; }
_o_get()   { cmd_get_incidents; }
is_xray_running() { return 1; }
_now=$(date +%s)

_t outage_lifecycle
_o_reset
_outage_open $((_now - 60)) "timeout"; _outage_open $((_now - 20)) "timeout"
assert_json "one-record"   "$(cat "$OJ")" 'length' 1
assert_json "ongoing"      "$(_o_get)" '.incidents[0].state' ongoing
_outage_close recovered
assert_json "recovered"    "$(_o_get)" '.incidents[0].state' recovered
assert_json "kept-start"   "$(_o_get)" ".incidents[0].ts == $((_now - 60))" true
assert_json "has-end"      "$(_o_get)" '.incidents[0].end >= .incidents[0].ts' true
assert_eq   "marker-gone"  "$([ -f "$OM" ] && echo yes || echo no)" no
_outage_close recovered; assert_rc "close-twice" "$?" 0
assert_json "stat-1"       "$(_o_get)" '.stats[0].count_24h' 1

_t outage_switch_stop
_o_reset; _outage_open "$_now" x; _outage_on_up 1
assert_json "switched"     "$(_o_get)" '[.incidents[0].state,.incidents[0].to]|join("/")' switched/NL
_o_reset; _outage_open "$_now" x; _outage_on_up 0
assert_json "same-server"  "$(_o_get)" '.incidents[0].state' recovered
_o_reset; _outage_open "$_now" x; _outage_on_stop
assert_json "stopped"      "$(_o_get)" '.incidents[0].state' stopped

_t outage_unknown_end
_o_reset; _outage_open "$_now" x; rm -f "$OM"               # reboot: marker lost
assert_json "reboot"       "$(_o_get)" '.incidents[0].state' unknown
_outage_open "$((_now + 1))" x; _outage_close recovered       # next one must not close it
assert_json "old-untouched" "$(_o_get)" '[.incidents[].state]|join(",")' recovered,unknown
_o_reset; _outage_open "$_now" x; echo "$_now $((_now - 5000)) uz UZ x" > "$OM"
assert_json "stale-marker" "$(_o_get)" '.incidents[0].state' unknown
_outage_close recovered
assert_json "stale-close"  "$(_o_get)" '.incidents[0].state' unknown
_o_reset; _outage_open "$_now" x; echo junk > "$OM"
assert_json "junk-marker"  "$(_o_get)" '.incidents[0].state' unknown
_outage_close recovered; assert_rc "junk-close" "$?" 0
fresh_config '{"selected_server":0,"running_intent":false}'
_o_reset; _outage_open "$_now" x
assert_json "vpn-off"      "$(_o_get)" '.incidents[0].state' unknown
fresh_config '{"selected_server":0,"running_intent":true}'

_t outage_op_busy
_o_reset; sleep 30 & _bg=$!; echo "$_bg" > "$ECLIPVPN_TMP/op.in_progress"
_outage_open "$_now" x
assert_json "op-suppressed" "$(cat "$OJ")" 'length' 0
kill "$_bg" 2>/dev/null; wait "$_bg" 2>/dev/null; _o_reset

_t wan_outage
echo "$_now" > "$ECLIPVPN_TMP/wan_down_since"; _log_incident wan_down uz "UZ x" d
assert_json "wan-ongoing"  "$(_o_get)" '.incidents[0].state' ongoing
assert_json "wan-not-server" "$(_o_get)" '.stats|length' 0
_outage_on_up 0
assert_json "wan-closed"   "$(_o_get)" '.incidents[0].state' recovered
assert_eq   "wan-marker"   "$([ -f "$ECLIPVPN_TMP/wan_down_since" ] && echo yes || echo no)" no

_t fold_legacy
_o_reset; a=$((_now - 4000))
printf '[{"ts":%s,"type":"check_fail","host":"uz","server":"UZ","detail":"t (3/5)"},{"ts":%s,"type":"check_fail","host":"uz","server":"UZ","detail":"t (4/5)"},{"ts":%s,"type":"check_fail","host":"uz","server":"UZ","detail":"t (5/5)"},{"ts":%s,"type":"check_fail","host":"uz","server":"UZ","detail":"t (3/5)"},{"ts":%s,"type":"wan_down","host":"uz","server":"UZ","detail":"w"},{"ts":%s,"type":"wan_recovered","host":"","server":"","detail":"r"}]' \
  "$a" $((a+39)) $((a+78)) $((a+2000)) $((a+2100)) $((a+2200)) > "$OJ"
assert_json "legacy"       "$(_o_get)" '[.incidents[]|.type+":"+.state]|join(",")' wan_down:recovered,outage:unknown,outage:unknown
assert_json "legacy-count" "$(_o_get)" '.stats[0].count_24h' 2

_t fold_auto_switch
_o_reset
printf '[{"ts":100,"type":"outage","host":"uz","server":"UZ","detail":"d","end":300,"closed":"switched","to":"NL"},{"ts":200,"type":"switch_failed","host":"uz","server":"UZ","detail":"все кандидаты недоступны"},{"ts":290,"type":"auto_switch","host":"nl","server":"NL","detail":"n"},{"ts":400,"type":"auto_switch","host":"nl","server":"NL","detail":"other"}]' > "$OJ"
assert_json "auto-folded"  "$(_o_get)" '[.incidents[].type]|join(",")' auto_switch,outage
assert_json "auto-flag"    "$(_o_get)" '.incidents[1]|[.auto,.noalt,.note]|join("/")' "true/1/n"
echo '[]' > "$OJ"; assert_json "empty" "$(_o_get)" '.incidents|length' 0
_log_incident x h n d; cmd_clear_incidents >/dev/null; rm -f "$OJ"; _restore_state
assert_json "clear-survives-reboot" "$(_o_get)" '.incidents|length' 0

_t xray_errors_are_scrubbed
_x=$(printf '%s\n' \
 '2026/11/24 01:00:00.1 [Warning] old > dial tcp 9.9.9.9:443: i/o timeout' \
 '2026/11/24 02:00:00.1 from tcp:127.0.0.1:1 accepted tcp:secret.example.com:443 [socks-in >> proxy]' \
 '2026/11/24 02:00:01.1 [Warning] [123] app/proxyman/outbound: failed to process outbound traffic > dial tcp 203.0.113.9:443: i/o timeout' \
 '2026/11/24 02:00:02.1 [Error] [9] bad tcp:secret.example.com:443 [2001:db8::1]:443 b831381d-6324-4d53-ad4f-8cda48b30811' \
 | _outage_xray_errors '2026/11/24 01:30:00')
assert_eq "x-lines"  "$(printf '%s\n' "$_x" | wc -l | tr -d ' ')" 2
assert_eq "x-cause"  "$(printf '%s\n' "$_x" | grep -c 'dial tcp …: i/o timeout')" 1
assert_eq "x-clean"  "$(printf '%s\n' "$_x" | grep -cE 'secret|203|2001|b831')" 0

_t probe_reasons
curl() { case "$*" in *ipify*) echo "000 0.1"; return 56 ;; *) echo "000 6.0"; return 28 ;; esac; }
_watchdog_probe_via_socks 1080; assert_rc "pr-rc" "$?" 1
assert_eq "pr-first" "$WD_PROBE_WHY" "таймаут >6с (HTTP 000)"
assert_eq "pr-all"   "$WD_PROBE_ALL" "Cloudflare: таймаут >6с (HTTP 000); Google: таймаут >6с (HTTP 000); ipify: разрыв соединения"

_t diag_tcp
is_xray_running() { return 0; }
_active_socks_port() { echo 1080; }
echo '{"outbounds":[{"settings":{"vnext":[{"address":"203.0.113.9","port":443,"users":[{"id":"u"}]}]}}]}' > "$ECLIPVPN_TMP/xray.1080.json"
curl() { case "$*" in *https://203.0.113.9:443/*) echo 0.175; return 60 ;; esac; return 1; }
assert_json "tcp-ok"   "$(_outage_diag "$_now")" .tcp "отвечает, 175 мс"
curl() { echo 0.000000; return 7; };  assert_json "tcp-refused" "$(_outage_diag "$_now")" .tcp "не открылся"
curl() { echo 0.000000; return 28; }; assert_json "tcp-timeout" "$(_outage_diag "$_now")" .tcp "нет ответа за 4 с"

unset -f curl _o_reset _o_get
rm -f "$OJ" "$OM" "$ECLIPVPN_TMP/servers.json" "$ECLIPVPN_TMP/xray.1080.json"
rm -rf "$(_state_mirror_dir)"
# shellcheck disable=SC1090
. "$REPO/usr/bin/eclipvpn"
