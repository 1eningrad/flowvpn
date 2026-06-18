# test_subscriptions.sh — _merge_sub_pool: the offline pool rebuild used by
# `sub enable/disable/remove` (no network fetch). Guards against the merge
# silently collapsing servers.json. Sourced by tests/run.sh against the real
# function; caches + servers.json live under the scratch ECLIPVPN_TMP.

# A minimal per-sub cache (already tagged sub_id, as update_subscription writes).
_cache() { printf '%s' "$2" > "$ECLIPVPN_TMP/sub.$1.servers.json"; }

_t "merge: two enabled subs concatenate in config order"
rm -f "$ECLIPVPN_TMP"/sub.*.servers.json "$ECLIPVPN_TMP/servers.json"
fresh_config '{"subscriptions":[{"id":"aaa","url":"https://a","enabled":true},{"id":"bbb","url":"https://b","enabled":true}],"selected_server":0}'
_cache aaa '[{"name":"A1","host":"1.1.1.1","port":443,"sub_id":"aaa"}]'
_cache bbb '[{"name":"B1","host":"2.2.2.2","port":443,"sub_id":"bbb"},{"name":"B2","host":"2.2.2.3","port":443,"sub_id":"bbb"}]'
cnt=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
assert_eq   "count"        "$cnt" "3"
assert_json "pool length"  "$(cat "$ECLIPVPN_TMP/servers.json")" 'length'       "3"
assert_json "aaa first"    "$(cat "$ECLIPVPN_TMP/servers.json")" '.[0].sub_id'  "aaa"
assert_json "bbb last"     "$(cat "$ECLIPVPN_TMP/servers.json")" '.[2].sub_id'  "bbb"

_t "merge: a disabled sub is excluded from the pool (cache may still exist)"
fresh_config '{"subscriptions":[{"id":"aaa","url":"https://a","enabled":true},{"id":"bbb","url":"https://b","enabled":false}],"selected_server":0}'
cnt=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
assert_eq   "count"        "$cnt" "1"
assert_json "only aaa left" "$(cat "$ECLIPVPN_TMP/servers.json")" '[.[].sub_id]|unique|join(",")' "aaa"

_t "merge: no enabled subs -> pool cleared to []"
fresh_config '{"subscriptions":[{"id":"aaa","url":"https://a","enabled":false},{"id":"bbb","url":"https://b","enabled":false}],"selected_server":0}'
cnt=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
assert_eq   "count"        "$cnt" "0"
assert_json "empty pool"   "$(cat "$ECLIPVPN_TMP/servers.json")" 'length' "0"

_t "merge: a missing cache is skipped, others survive (no collapse)"
fresh_config '{"subscriptions":[{"id":"aaa","url":"https://a","enabled":true},{"id":"ccc","url":"https://c","enabled":true}],"selected_server":0}'
_cache aaa '[{"name":"A1","host":"1.1.1.1","port":443,"sub_id":"aaa"}]'
rm -f "$ECLIPVPN_TMP/sub.ccc.servers.json"
cnt=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
assert_eq   "count (ccc absent)" "$cnt" "1"
assert_json "aaa survived"  "$(cat "$ECLIPVPN_TMP/servers.json")" '.[0].sub_id' "aaa"

_t "merge: a corrupt (non-array) cache is skipped, not fatal"
fresh_config '{"subscriptions":[{"id":"aaa","url":"https://a","enabled":true},{"id":"ddd","url":"https://d","enabled":true}],"selected_server":0}'
_cache aaa '[{"name":"A1","host":"1.1.1.1","port":443,"sub_id":"aaa"}]'
_cache ddd '{"not":"an array"}'
cnt=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
assert_eq   "count (ddd corrupt)" "$cnt" "1"

rm -f "$ECLIPVPN_TMP"/sub.*.servers.json "$ECLIPVPN_TMP/servers.json"
