# Scenario tests for the watchdog's per-tick guards (_wd_* in watchdog.sh).
# Each guard is driven with hand-set state and stubbed probes/restarts — the
# real decision code runs, nothing touches the network or spawns xray. State
# lives in plain globals here; in production it is cmd_watchdog's locals,
# which the guards reach through ash's dynamic scoping.

# --- stubs -------------------------------------------------------------------
# Side effects are recorded in a FILE, not a variable: the guards call
# cmd_restart / cmd_start inside ( subshells ), which can't update our vars.
WD_CALLS="$ECLIPVPN_TMP/wd_calls"
_calls()   { cat "$WD_CALLS" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
_reset()   { : > "$WD_CALLS"; rm -f "$ECLIPVPN_TMP"/wan_down_* "$ECLIPVPN_TMP"/last_revive \
                 "$ECLIPVPN_TMP"/net_check_prev.json "$ECLIPVPN_TMP"/op.in_progress \
                 "$ECLIPVPN_TMP"/dns_direct_active; }
logger()          { :; }
sleep()           { :; }
cmd_restart()     { echo "restart${1:+:$1}" >> "$WD_CALLS"; }
cmd_start()       { echo "start" >> "$WD_CALLS"; }
_log_incident()   { echo "inc:$1" >> "$WD_CALLS"; }
_record_switch()  { echo "switch:$1>$2:$3" >> "$WD_CALLS"; }

servers='[{"name":"A","host":"a"},{"name":"B","host":"b"},{"name":"C WL","host":"c"},{"name":"D","host":"d"},{"name":"Обход","host":"e"}]'
printf '%s' "$servers" > "$ECLIPVPN_TMP/servers.json"
interval=20; probe_port=1182; max_fails=5

# --- throughput guard ----------------------------------------------------------
_t tput_guard
TPUT_EVERY=6; TPUT_SLOW_MAX=3; TPUT_COOLDOWN=1200; TPUT_COOLDOWN_FAST=300
_tput_state() { slow_count=0; last_tput_switch=0; tput_switch_helped=1; tput_redialed=0; tput_fast_retry_used=0; }
tick=6
fresh_config '{"selected_server":0}'; _reset; _tput_state
_watchdog_throughput_kbps() { echo 100; }
_watchdog_probe_candidate() { echo "ok 5000"; }    # fresh flow to the same server is fast
_wd_tput_guard; _wd_tput_guard
assert_eq "tg-counting"       "$slow_count" 2
assert_eq "tg-no-action-yet"  "$(_calls)" ""
_wd_tput_guard
assert_eq "tg-redial"         "$(_calls)" "inc:slow_redial restart:1"
assert_eq "tg-redial-reset"   "$slow_count/$tput_redialed/$tput_switch_helped" "0/1/0"

# Re-squeezed before any good reading (a flop): the fast cooldown gates the retry.
_reset; last_tput_switch=$(date +%s)
_watchdog_pick_best() { echo "3 3000"; }
_wd_tput_guard; _wd_tput_guard; _wd_tput_guard
assert_eq "tg-cooldown-holds" "$(_calls)" ""
# Past the FAST cooldown: the one early retry is spent — re-dial already used,
# so it benchmarks and switches.
last_tput_switch=$(( $(date +%s) - 400 ))
_wd_tput_guard
assert_eq "tg-fast-retry"     "$(_calls)" "inc:slow_degraded switch:0>3:throughput restart"
assert_eq "tg-switched"       "$(get_config_val selected_server x)" 3
assert_eq "tg-retry-spent"    "$tput_fast_retry_used/$tput_redialed" "1/0"

# A good reading lifts the gate and re-arms both budgets.
_watchdog_throughput_kbps() { echo 9000; }
_wd_tput_guard
assert_eq "tg-good-rearms"    "$slow_count/$tput_switch_helped/$tput_redialed/$tput_fast_retry_used" "0/1/0/0"

# Candidate not >2x faster than the crawl ⇒ stay put (slow_noalt).
fresh_config '{"selected_server":0}'; _reset; _tput_state; tput_redialed=1
_watchdog_throughput_kbps() { echo 400; }
_watchdog_pick_best() { echo "3 700"; }
_wd_tput_guard; _wd_tput_guard; _wd_tput_guard
assert_eq "tg-noalt"          "$(_calls)" "inc:slow_noalt"
assert_eq "tg-noalt-stays"    "$(get_config_val selected_server x)" 0

# auto_failover=false: re-dial still allowed, switch is not.
fresh_config '{"selected_server":0,"auto_failover":false}'; _reset; _tput_state
_watchdog_throughput_kbps() { echo 100; }
_watchdog_probe_candidate() { echo "ok 150"; }     # fresh flow also slow ⇒ no re-dial
_wd_tput_guard; _wd_tput_guard; _wd_tput_guard
assert_eq "tg-af-off"         "$(_calls)" "inc:slow_noswitch"
assert_eq "tg-af-off-stays"   "$(get_config_val selected_server x)" 0

# Off-tick and tput_guard=false do nothing.
fresh_config '{"tput_guard":false}'; _reset; _tput_state
_wd_tput_guard; _wd_tput_guard; _wd_tput_guard
assert_eq "tg-disabled"       "$slow_count$(_calls)" "0"
fresh_config '{}'; tick=7; _wd_tput_guard
assert_eq "tg-off-tick"       "$slow_count" 0
tick=6

# --- probe failure: WAN-down vs server-down, failover scan ----------------------
_t probe_fail
fresh_config '{"selected_server":0}'; _reset; fail_count=0; silent_fails=0
_watchdog_check_wan() { return 1; }
_wd_on_probe_fail "timeout"; _wd_on_probe_fail "timeout"
assert_eq "pf-wan-once"       "$(_calls)" "inc:wan_down"
assert_eq "pf-wan-ticks"      "$(cat "$ECLIPVPN_TMP/wan_down_ticks")" 2
assert_eq "pf-wan-no-count"   "$fail_count" 0
# Recovery closes it out with one wan_recovered.
_reset_keep_wan() { : > "$WD_CALLS"; }; _reset_keep_wan
_wd_on_probe_ok
assert_eq "pf-wan-recovered"  "$(_calls)" "inc:wan_recovered"

_reset; fail_count=0
_watchdog_check_wan() { return 0; }
_watchdog_pick_best() { [ "${5:-normal}" = normal ] && echo "3 120"; }
_wd_on_probe_fail x; _wd_on_probe_fail x
assert_eq "pf-quiet-1-2"      "$(_calls)" ""
_wd_on_probe_fail x; _wd_on_probe_fail x
assert_eq "pf-incident-3-4"   "$(_calls)" "inc:check_fail inc:check_fail"
: > "$WD_CALLS"; _wd_on_probe_fail x
assert_eq "pf-switch-at-5"    "$(_calls)" "inc:check_fail inc:auto_switch switch:0>3:failover restart"
assert_eq "pf-reset"          "$fail_count/$(get_config_val selected_server x)" "0/3"

# Nothing un-muted answers ⇒ emergency pass over muted ones.
fresh_config '{"selected_server":0,"muted_servers":"Обход"}'; _reset; fail_count=4
_watchdog_pick_best() { [ "${5:-normal}" = muted_only ] && echo "4 200"; }
_wd_on_probe_fail x
assert_eq "pf-emergency"      "$(_calls)" "inc:check_fail inc:emergency_muted switch:0>4:failover restart"

# auto_failover=false ⇒ counts, never switches.
fresh_config '{"selected_server":0,"auto_failover":false}'; _reset; fail_count=4
_wd_on_probe_fail x
assert_eq "pf-af-off"         "$(_calls)" "inc:check_fail"
assert_eq "pf-af-off-stays"   "$(get_config_val selected_server x)" 0

# No candidate ⇒ switch_failed; scan re-arms every 15 ticks, silent in between.
fresh_config '{"selected_server":0}'; _reset; fail_count=4; silent_fails=0
_watchdog_pick_best() { :; }
_wd_on_probe_fail x
assert_eq "pf-no-cand"        "$(_calls)" "inc:check_fail inc:switch_failed"
: > "$WD_CALLS"; i=0; while [ "$i" -lt 14 ]; do _wd_on_probe_fail x; i=$((i+1)); done
assert_eq "pf-silent-between" "$(_calls)" ""
_wd_on_probe_fail x
assert_eq "pf-rearm-at-20"    "$fail_count/$(_calls)" "20/inc:switch_failed"

# --- revival ------------------------------------------------------------------
_t revive
fresh_config '{"running_intent":true}'; _reset
_wd_revive
assert_eq "rv-start"          "$(_calls)" "start"
: > "$WD_CALLS"; _wd_revive
assert_eq "rv-cooldown"       "$(_calls)" ""
_reset; echo $$ > "$ECLIPVPN_TMP/op.in_progress"
_wd_revive
assert_eq "rv-defer-op"       "$(_calls)" ""
_reset; fresh_config '{"running_intent":false}'
_wd_revive
assert_eq "rv-no-intent"      "$(_calls)" ""

# --- net-check guard ------------------------------------------------------------
_t net_check
NET_EVERY=15; NET_STREAK=2; tick=15; net_wl_streak=0; net_full_streak=0
fresh_config '{"selected_server":0}'; _reset
cmd_net_check() { echo '{"internet":"whitelist"}'; }
_net_check_pick() { [ "$4" = 1 ] && echo "2 80"; }
_wd_net_check_guard
assert_eq "nc-streak-1"       "$net_wl_streak/$(_calls)" "1/"
_wd_net_check_guard
assert_eq "nc-wl-switch"      "$(_calls)" "inc:net_check_switch switch:0>2:net_check_whitelist restart"
assert_json "nc-prev-saved"   "$(cat "$ECLIPVPN_TMP/net_check_prev.json")" '.name' A
# Uplink back to full ⇒ restore the remembered server after the streak.
: > "$WD_CALLS"
cmd_net_check() { echo '{"internet":"full"}'; }
_watchdog_probe_candidate() { echo "ok 60"; }
_wd_net_check_guard; _wd_net_check_guard
assert_eq "nc-restore"        "$(_calls)" "inc:net_check_restore switch:2>0:net_check_full restart"
assert_eq "nc-prev-cleared"   "$([ -f "$ECLIPVPN_TMP/net_check_prev.json" ] && echo yes || echo no)" no
# Gated by auto_failover.
fresh_config '{"selected_server":0,"auto_failover":false}'; _reset; net_wl_streak=0
cmd_net_check() { echo '{"internet":"whitelist"}'; }
_wd_net_check_guard; _wd_net_check_guard
assert_eq "nc-af-off"         "$net_wl_streak/$(_calls)" "0/"

# --- direct DNS guard -------------------------------------------------------------
_t dns_guard
fresh_config '{"dns_direct_servers":"9.9.9.9,8.8.4.4"}'; _reset; dns_fail=0; DNS_FAIL_MAX=2
_dns_probe() { [ "$1" = "8.8.4.4" ]; }
_watchdog_check_wan() { return 0; }
_wd_dns_guard
assert_eq "dg-first-miss"     "$dns_fail/$(_calls)" "1/"
_wd_dns_guard
assert_eq "dg-failover"       "$(_calls)" "inc:dns_failover restart"
assert_eq "dg-active"         "$(cat "$ECLIPVPN_TMP/dns_direct_active")" 8.8.4.4

# --- auto_eval (watchdog's auto_mode re-pick) honours auto_failover --------------
_t auto_eval_gate
printf '%s' "$servers" > "$ECLIPVPN_TMP/servers.json"
_vpn_running() { return 0; }
test_xray()    { echo 1.2.3.4; }
_reach_ms()    { echo "reach" >> "$WD_CALLS"; echo -1; }
fresh_config '{"selected_server":0,"auto_failover":false}'; _reset; rm -f "$ECLIPVPN_TMP/auto_state.json"
assert_json "ae-af-off"       "$(cmd_auto_eval)" '.status' skipped
assert_eq   "ae-af-off-noprobe" "$(_calls)" ""
fresh_config '{"selected_server":0}'; _reset; rm -f "$ECLIPVPN_TMP/auto_state.json"
cmd_auto_eval >/dev/null 2>&1
assert_eq   "ae-af-on-probes" "$(_calls | cut -d' ' -f1)" reach
rm -f "$ECLIPVPN_TMP/auto_state.json" "$ECLIPVPN_TMP/auto.lock"

# --- restore every real function the stubs replaced ---------------------------
rm -f "$ECLIPVPN_TMP/servers.json" "$WD_CALLS"; _reset
unset -f logger sleep _calls _reset _reset_keep_wan _tput_state
# shellcheck disable=SC1090
. "$REPO/usr/bin/eclipvpn"

# --- link state for /status ----------------------------------------------------
_t link_state
_now=$(date +%s)
rm -f "$ECLIPVPN_TMP"/probe_fails "$ECLIPVPN_TMP"/wan_down_since
assert_eq "ls-no-marker"   "$(_link_state 0)" ok
echo "2 $_now" > "$ECLIPVPN_TMP/probe_fails";             assert_eq "ls-jitter"  "$(_link_state 0)" ok
echo "3 $_now" > "$ECLIPVPN_TMP/probe_fails";             assert_eq "ls-lost"    "$(_link_state 0)" lost
assert_eq "ls-older-than-start" "$(_link_state $((_now + 1)))" ok
echo "9 $((_now - 500))" > "$ECLIPVPN_TMP/probe_fails";   assert_eq "ls-stale"   "$(_link_state 0)" ok
echo "junk" > "$ECLIPVPN_TMP/probe_fails";                assert_eq "ls-garbage" "$(_link_state 0)" ok
echo "$_now" > "$ECLIPVPN_TMP/wan_down_since";            assert_eq "ls-wan"     "$(_link_state 0)" wan
rm -f "$ECLIPVPN_TMP"/wan_down_since
fail_count=4; silent_fails=0; _wd_on_probe_ok
assert_eq "ls-ok-clears" "$([ -f "$ECLIPVPN_TMP/probe_fails" ] && echo yes || echo no)" no
