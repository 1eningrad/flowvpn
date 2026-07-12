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

# --- manual single-server "subscriptions" (a vless:// URI instead of a URL) --
# cmd_sub add accepts a bare proxy URI: it becomes a subscriptions[] entry with
# manual:true whose cache is parsed locally (no network), mirrored to the
# persistent subcache, and merged like any provider.
MURI='vless://manual-uuid@5.6.7.8:443?security=reality&pbk=PK&sni=m.com&type=xhttp#Мой сервер'
SCACHE="$(dirname "$ECLIPVPN_CONFIG")/subcache"

_t "manual add: vless:// URI becomes a single-server subscription (offline)"
rm -f "$ECLIPVPN_TMP"/sub.*.servers.json "$ECLIPVPN_TMP/servers.json"
rm -rf "$SCACHE"
fresh_config '{"subscriptions":[],"selected_server":0,"mode":"all_vpn"}'
out=$(cmd_sub add "$MURI")
assert_json "status added"   "$out" '.status' "added"
assert_json "manual flag"    "$out" '.manual' "true"
mid=$(printf '%s' "$out" | jq -r '.id')
assert_json "entry manual"   "$(cat "$ECLIPVPN_CONFIG")" '.subscriptions[0].manual' "true"
assert_json "name from #fragment" "$(cat "$ECLIPVPN_CONFIG")" '.subscriptions[0].name' "Мой сервер"
assert_json "legacy mirror stays empty (uri is not fetchable)" "$(cat "$ECLIPVPN_CONFIG")" '.subscription_url' ""
assert_json "pool has the server" "$(cat "$ECLIPVPN_TMP/servers.json")" '.[0].host' "5.6.7.8"
assert_json "tagged sub_id"  "$(cat "$ECLIPVPN_TMP/servers.json")" '.[0].sub_id' "$mid"
assert_eq   "persistent subcache mirror written" \
    "$([ -s "$SCACHE/sub.$mid.servers.json" ] && echo y || echo n)" "y"

_t "manual add: idempotent — re-adding the same URI keeps one entry"
out=$(cmd_sub add "$MURI")
assert_json "same id"     "$out" '.id' "$mid"
assert_json "still 1 sub" "$(cat "$ECLIPVPN_CONFIG")" '.subscriptions|length' "1"

_t "manual add: a user-supplied name wins over the #fragment"
fresh_config '{"subscriptions":[],"selected_server":0,"mode":"all_vpn"}'
out=$(cmd_sub add "$MURI" "Дача")
assert_json "custom name" "$(cat "$ECLIPVPN_CONFIG")" '.subscriptions[0].name' "Дача"

_t "manual add: unparseable URI is rejected, nothing saved"
fresh_config '{"subscriptions":[],"selected_server":0,"mode":"all_vpn"}'
out=$(cmd_sub add 'vless://u@0.0.0.0:443')
assert_json "error returned" "$out" '.error != null' "true"
assert_json "no entry added" "$(cat "$ECLIPVPN_CONFIG")" '.subscriptions|length' "0"

_t "manual add: unknown scheme is rejected"
out=$(cmd_sub add 'wireguard://whatever')
assert_json "error returned" "$out" '.error != null' "true"

_t "manual + http mix: legacy mirror tracks the first FETCHABLE sub"
rm -f "$ECLIPVPN_TMP"/sub.*.servers.json "$ECLIPVPN_TMP/servers.json"
fresh_config '{"subscriptions":[],"selected_server":0,"mode":"all_vpn"}'
cmd_sub add "$MURI" >/dev/null
fresh_config "$(jq -c '.subscriptions += [{"id":"hhh","name":"Panel","url":"https://panel.example/sub","enabled":true}] | .subscription_url=""' "$ECLIPVPN_CONFIG")"
_cache hhh '[{"name":"H1","host":"9.9.9.9","port":443,"sub_id":"hhh"}]'
out=$(cmd_sub add "$MURI")   # idempotent re-add re-runs the mirror expression
assert_json "mirror = the http sub" "$(cat "$ECLIPVPN_CONFIG")" '.subscription_url' "https://panel.example/sub"
cnt=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
assert_eq "both subs merge" "$cnt" "2"

_t "merge self-heal: a manual sub's missing cache is rebuilt from its URI"
fresh_config '{"subscriptions":[],"selected_server":0,"mode":"all_vpn"}'
cmd_sub add "$MURI" >/dev/null
rm -f "$ECLIPVPN_TMP"/sub.*.servers.json "$ECLIPVPN_TMP/servers.json"
rm -rf "$SCACHE"
cnt=$(_merge_sub_pool "$ECLIPVPN_CONFIG")
assert_eq   "count"          "$cnt" "1"
assert_json "server rebuilt" "$(cat "$ECLIPVPN_TMP/servers.json")" '.[0].host' "5.6.7.8"

_t "manual remove: entry, cache and persistent mirror are pruned"
out=$(cmd_sub remove "$mid")
assert_json "removed"       "$out" '.status' "removed"
assert_json "no subs left"  "$(cat "$ECLIPVPN_CONFIG")" '.subscriptions|length' "0"
assert_eq   "tmp cache gone" "$([ -e "$ECLIPVPN_TMP/sub.$mid.servers.json" ] && echo y || echo n)" "n"
assert_eq   "subcache mirror gone" "$([ -e "$SCACHE/sub.$mid.servers.json" ] && echo y || echo n)" "n"

rm -f "$ECLIPVPN_TMP"/sub.*.servers.json "$ECLIPVPN_TMP/servers.json"
rm -rf "$SCACHE"
