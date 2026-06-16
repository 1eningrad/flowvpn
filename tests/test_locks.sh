# test_locks.sh — the op-lock (TOCTOU fix) and config-lock primitives. run.sh env.

_reset_op()  { rm -f "$ECLIPVPN_TMP/op.lock" "$ECLIPVPN_TMP/op.in_progress"; rm -rf "$ECLIPVPN_TMP/op.reclaim.lockdir"; }
_reset_cfg() { rm -f "$ECLIPVPN_TMP/config.lock"; rm -rf "$ECLIPVPN_TMP/config.reclaim.lockdir"; }

# --- _op_begin / _op_end ---
_t op_lock
_reset_op
_op_begin; assert_rc "op-acquire" "$?" 0
assert_eq "op-owner" "$(readlink "$ECLIPVPN_TMP/op.lock")" "$$"
# second acquire by a live owner -> rejected, not stolen
_op_begin; assert_rc "op-reject-held" "$?" 1
_op_end
assert_eq "op-released" "$( [ -e "$ECLIPVPN_TMP/op.lock" ] && echo present || echo gone )" gone

# stale reclaim: a symlink owned by a guaranteed-dead PID is reclaimable
_reset_op
ln -s 999999 "$ECLIPVPN_TMP/op.lock"
_op_begin; assert_rc "op-reclaim-dead" "$?" 0
assert_eq "op-reclaim-newowner" "$(readlink "$ECLIPVPN_TMP/op.lock")" "$$"
_op_end

# THE FIX: live owner in the empty-owner window (symlink set, op.in_progress
# absent) must NOT be stolen. Old mkdir+pidfile lock stole here -> two starts.
_reset_op
sleep 30 & HOLDER=$!
ln -s "$HOLDER" "$ECLIPVPN_TMP/op.lock" 2>/dev/null
rm -f "$ECLIPVPN_TMP/op.in_progress"
_op_begin; assert_rc "op-no-steal-live" "$?" 1
assert_eq "op-owner-unchanged" "$(readlink "$ECLIPVPN_TMP/op.lock")" "$HOLDER"
kill "$HOLDER" 2>/dev/null
_reset_op

# concurrency: 12 racing _op_begin (none release) -> exactly one winner
_reset_op
: > "$ECLIPVPN_TMP/op_wins"
i=0; while [ "$i" -lt 12 ]; do ( _op_begin && echo x >> "$ECLIPVPN_TMP/op_wins" ) & i=$((i + 1)); done
wait
assert_eq "op-one-winner" "$(wc -l < "$ECLIPVPN_TMP/op_wins" | tr -d ' ')" 1
_reset_op; rm -f "$ECLIPVPN_TMP/op_wins"

# --- _config_lock / _config_unlock ---
_t config_lock
_reset_cfg
_config_lock; assert_rc "cfg-acquire" "$?" 0
assert_eq "cfg-owner" "$(readlink "$ECLIPVPN_TMP/config.lock")" "$$"
_config_unlock
assert_eq "cfg-released" "$( [ -e "$ECLIPVPN_TMP/config.lock" ] && echo present || echo gone )" gone
# stale reclaim
ln -s 999999 "$ECLIPVPN_TMP/config.lock"
_config_lock; assert_rc "cfg-reclaim-dead" "$?" 0
assert_eq "cfg-reclaim-newowner" "$(readlink "$ECLIPVPN_TMP/config.lock")" "$$"
_config_unlock
_reset_cfg
