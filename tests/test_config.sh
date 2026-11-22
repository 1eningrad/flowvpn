# test_config.sh — update_config: locked read-modify-write of config.json. run.sh env.

# basic key set
_t update_config_basic
fresh_config '{"n":0,"mode":"all_vpn"}'
update_config '.mode=$m' --arg m blocklist
assert_eq "set-mode" "$(jq -r .mode "$ECLIPVPN_CONFIG")" blocklist
assert_eq "still-valid" "$(jq -e . "$ECLIPVPN_CONFIG" >/dev/null 2>&1 && echo ok)" ok

# argjson numeric
update_config '.selected_server=$i' --argjson i 7
assert_eq "set-selected" "$(jq -r .selected_server "$ECLIPVPN_CONFIG")" 7

# concurrency: 10 racing increments under the lock -> exactly 10 (no lost update)
_t update_config_concurrency
fresh_config '{"n":0}'
i=0; while [ "$i" -lt 10 ]; do update_config '.n += 1' & i=$((i + 1)); done
wait
assert_eq "concurrent-incr" "$(jq -r .n "$ECLIPVPN_CONFIG")" 10

# replace-form (restore path): program ignores stdin, emits the arg
_t update_config_replace
fresh_config '{"n":1,"old":true}'
update_config '$repl' --argjson repl '{"restored":true,"k":9}'
assert_eq "replace-restored" "$(jq -r '.restored' "$ECLIPVPN_CONFIG")" true
assert_eq "replace-dropped-old" "$(jq -r '.old // "absent"' "$ECLIPVPN_CONFIG")" absent

# jq-failure: bad program -> rc 1, config untouched, lock freed
_t update_config_badjq
fresh_config '{"keep":42}'
update_config 'this is not valid jq ((('; rc=$?
assert_rc "badjq-rc" "$rc" 1
assert_eq "badjq-untouched" "$(jq -r .keep "$ECLIPVPN_CONFIG")" 42
assert_eq "badjq-lock-freed" "$( [ -e "$ECLIPVPN_TMP/config.lock" ] && echo present || echo gone )" gone

# save_config backup rotation: a non-volatile change rotates config.json.1
_t save_config_backups
fresh_config '{"mode":"all_vpn","selected_server":0}'
rm -f "$ECLIPVPN_CONFIG".1 "$ECLIPVPN_CONFIG".2 "$ECLIPVPN_CONFIG".3
update_config '.mode=$m' --arg m blocklist
assert_eq "backup-1-made" "$( [ -f "$ECLIPVPN_CONFIG".1 ] && echo yes || echo no )" yes
# a volatile-only change (selected_server) must NOT rotate the backup history
cp "$ECLIPVPN_CONFIG".1 "$ECLIPVPN_TMP/bk_before"
update_config '.selected_server=$i' --argjson i 3
assert_eq "backup-not-churned-by-volatile" \
    "$(cmp -s "$ECLIPVPN_CONFIG".1 "$ECLIPVPN_TMP/bk_before" && echo same || echo changed)" same
rm -f "$ECLIPVPN_TMP/bk_before"

# restore stub-guard predicate: accept real configs, reject truncated/foreign
# blobs (the class that stubbed prod 2026-06-17 — restore is a FULL replace).
_t restore_config_sane_predicate
_restore_config_sane '{"config":{"mode":"blocklist","subscriptions":[]}}';            rc=$?; assert_rc "accept-multisub"  "$rc" 0
_restore_config_sane '{"config":{"mode":"all_vpn","subscription_url":"https://x"}}';   rc=$?; assert_rc "accept-legacy"    "$rc" 0
_restore_config_sane '{"config":{"subscriptions":[],"auto_start":true}}';             rc=$?; assert_rc "reject-no-mode"   "$rc" 1
_restore_config_sane '{"direct_domains":""}';                                          rc=$?; assert_rc "reject-no-config" "$rc" 1
_restore_config_sane '{"config":"oops"}';                                              rc=$?; assert_rc "reject-nonobject" "$rc" 1
_restore_config_sane '{"config":{"mode":"banana","subscriptions":[]}}';                rc=$?; assert_rc "reject-bad-mode"  "$rc" 1

# cmd_restore integration: a stub blob is rejected (rc 1) and the LIVE config is
# left completely untouched — no full-replace into a husk. Pass the blob as the
# arg (as the dispatcher does: `cmd_restore "$2"`); the stdin form would trip
# run.sh's `set -u` on the unset $1, which production never hits.
_t restore_rejects_stub_leaves_config
fresh_config '{"mode":"all_vpn","subscriptions":[{"id":"keepme"}],"auto_start":true}'
cmd_restore '{"config":{"running_intent":true,"selected_server":0,"subscriptions":[]}}' >/dev/null 2>&1; rc=$?
assert_rc "stub-rejected"          "$rc" 1
assert_eq "stub-config-mode-kept"  "$(jq -r .mode "$ECLIPVPN_CONFIG")" all_vpn
assert_eq "stub-config-subs-kept"  "$(jq -r '.subscriptions[0].id' "$ECLIPVPN_CONFIG")" keepme

# --- get_config_val: default only for absent/null, never for a stored false ---
# `.[$k] // $d` returned the default for `false`, so true-default booleans
# (auto_failover, tput_guard, net_check_switch) could never be switched off.
_t get_config_val_false
fresh_config '{"auto_failover":false,"n":null,"s":"","z":0}'
assert_eq "gcv-false-kept"   "$(get_config_val auto_failover true)" false
assert_eq "gcv-absent-def"   "$(get_config_val missing dflt)"       dflt
assert_eq "gcv-null-def"     "$(get_config_val n dflt)"             dflt
assert_eq "gcv-empty-kept"   "$(get_config_val s dflt)"             ""
assert_eq "gcv-zero-kept"    "$(get_config_val z 5)"                0
