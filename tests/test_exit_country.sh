# Measured exit-country gate: the pure matcher, the config default/clear
# semantics, the set-config gate, the CF-trace parser, and that the watchdog
# candidate scan skips a blocked exit without treating it as a WAN failure.
# The live probe (throwaway xray/sing-box) is stubbed — that part needs a router.

# --- _country_blocked (pure) ---
_t country_blocked
_country_blocked RU "RU";          assert_rc "cb-hit"         "$?" 0
_country_blocked BY "RU,BY";       assert_rc "cb-hit-2nd"     "$?" 0
_country_blocked FI "RU,BY";       assert_rc "cb-miss"        "$?" 1
# Unknown country must NOT block (fail-open, see _country_blocked).
_country_blocked "" "RU";          assert_rc "cb-unknown"     "$?" 1
# Empty list = check disabled.
_country_blocked RU "";            assert_rc "cb-off"         "$?" 1
# Exact token match, not substring.
_country_blocked R "RU";           assert_rc "cb-no-substr"   "$?" 1

# --- _blocked_exit_countries: absent ⇒ RU, cleared ⇒ "" ---
_t blocked_default
fresh_config '{}'
assert_eq "bec-default"  "$(_blocked_exit_countries)" RU
fresh_config '{"blocked_exit_countries":""}'
assert_eq "bec-cleared"  "$(_blocked_exit_countries)" ""
fresh_config '{"blocked_exit_countries":"RU,BY"}'
assert_eq "bec-list"     "$(_blocked_exit_countries)" "RU,BY"

# --- set-config gate (CGI-reachable) ---
_t blocked_set_config
fresh_config '{}'
assert_json "sc-norm"    "$(cmd_set_config blocked_exit_countries 'ru, by')" '.value' 'RU,BY'
assert_eq   "sc-stored"  "$(get_config_val blocked_exit_countries x)" 'RU,BY'
cmd_set_config blocked_exit_countries 'RUS' >/dev/null 2>&1;  assert_rc "sc-3letter" "$?" 1
cmd_set_config blocked_exit_countries 'R1'  >/dev/null 2>&1;  assert_rc "sc-digit"   "$?" 1
cmd_set_config blocked_exit_countries 'RU;rm' >/dev/null 2>&1; assert_rc "sc-junk"  "$?" 1
assert_eq   "sc-unchanged" "$(get_config_val blocked_exit_countries x)" 'RU,BY'
assert_json "sc-off"     "$(cmd_set_config blocked_exit_countries off)" '.value' ''
assert_eq   "sc-off-read" "$(_blocked_exit_countries)" ''

# --- _exit_country parses CF trace (curl stubbed) ---
_t exit_country_parse
curl() { printf 'fl=1\nh=cp.cloudflare.com\nip=1.2.3.4\nloc=ru\ntls=TLSv1.3\n'; }
assert_eq "ec-parse-lower" "$(_exit_country 1182)" RU
curl() { printf 'fl=1\nip=1.2.3.4\n'; }
assert_eq "ec-no-loc"      "$(_exit_country 1182)" ""
curl() { printf 'loc=XYZ\n'; }
assert_eq "ec-bad-loc"     "$(_exit_country 1182)" ""
curl() { return 7; }
assert_eq "ec-curl-fail"   "$(_exit_country 1182)" ""
unset -f curl

# --- _watchdog_pick_best: blocked exit is skipped, not a WAN failure ---
_t pick_best_country
fresh_config '{}'
printf '%s' '[{"name":"cur"},{"name":"Россия (прямой)"},{"name":"Россия → Финляндия"},{"name":"Германия"}]' \
    > "$ECLIPVPN_TMP/servers.json"
WAN_CHECKS=0
_watchdog_check_wan() { WAN_CHECKS=$((WAN_CHECKS + 1)); return 0; }
# idx1 exits RU (fastest!), idx2 FI, idx3 DE slower. The RU one must lose.
_watchdog_probe_candidate() {
    case "$1" in
        1) [ -n "$4" ] && _country_blocked RU "$4" && { echo "blocked RU"; return; }; echo "ok 10" ;;
        2) echo "ok 50" ;;
        3) echo "ok 90" ;;
    esac
}
assert_eq "pb-skips-ru"     "$(_watchdog_pick_best 0 4 1182)" "2 50"
# With the check off, the fastest (RU) wins again — proves the gate is the cause.
fresh_config '{"blocked_exit_countries":""}'
assert_eq "pb-off-picks-ru" "$(_watchdog_pick_best 0 4 1182)" "1 10"
# Two blocked in a row must not trip the WAN-down abort (they answered).
fresh_config '{}'
_watchdog_probe_candidate() { case "$1" in 1|2) echo "blocked RU" ;; 3) echo "ok 90" ;; esac; }
WAN_CHECKS=0
_watchdog_pick_best 0 4 1182 >/dev/null
assert_eq "pb-no-wan-check" "$WAN_CHECKS" 0
assert_eq "pb-falls-through" "$(_watchdog_pick_best 0 4 1182)" "3 90"
rm -f "$ECLIPVPN_TMP/servers.json"
# Restore the real watchdog functions for any suite that runs after this one.
# shellcheck disable=SC1090
. "$ECLIPVPN_LIB/watchdog.sh"
