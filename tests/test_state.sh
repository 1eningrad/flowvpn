# test_state.sh — persistent mirror of the failover journal. Sourced by run.sh.
#
# incidents.json / last_switch.json live in $ECLIPVPN_TMP, which /tmp wipes on
# reboot. They are mirrored next to the config so a power cut can't erase the
# record of the outage that caused it. The mirror dir is derived from
# ECLIPVPN_CONFIG's dirname, so these tests stay inside the scratch sandbox.

fresh_config '{"mode":"all_vpn"}'
MIRROR="$(_state_mirror_dir)"

_t state_mirror_dir
# Must sit next to the config, never at a hardcoded /etc path — otherwise the
# suite would write into the live install (the isolation guard in run.sh).
assert_eq "mirror-in-sandbox" "$(dirname "$MIRROR")" "$(dirname "$ECLIPVPN_CONFIG")"
assert_eq "mirror-basename"   "$(basename "$MIRROR")" "state"

_t mirror_state
rm -rf "$MIRROR"; rm -f "$ECLIPVPN_TMP/incidents.json"
# missing source: must be a silent no-op, never an error the caller sees
_mirror_state incidents.json; assert_rc "mirror-missing-ok" "$?" 0
assert_eq "mirror-missing-nofile" "$([ -f "$MIRROR/incidents.json" ] && echo yes || echo no)" no
# empty source is also skipped — mirroring a truncated file would destroy history
: > "$ECLIPVPN_TMP/incidents.json"
_mirror_state incidents.json
assert_eq "mirror-empty-skip" "$([ -f "$MIRROR/incidents.json" ] && echo yes || echo no)" no
# real content gets mirrored, and no .tmp scratch is left behind
echo '[{"ts":1,"type":"probe"}]' > "$ECLIPVPN_TMP/incidents.json"
_mirror_state incidents.json
assert_eq "mirror-copied"  "$(cat "$MIRROR/incidents.json" 2>/dev/null)" '[{"ts":1,"type":"probe"}]'
assert_eq "mirror-no-tmp"  "$([ -f "$MIRROR/incidents.json.tmp" ] && echo yes || echo no)" no

_t restore_state
# /tmp wiped (the reboot case) -> refilled from the mirror
rm -f "$ECLIPVPN_TMP/incidents.json"
_restore_state
assert_eq "restore-refills" "$(cat "$ECLIPVPN_TMP/incidents.json" 2>/dev/null)" '[{"ts":1,"type":"probe"}]'
# a FRESHER /tmp copy must never be clobbered by an older mirror
echo '[{"ts":99,"type":"newer"}]' > "$ECLIPVPN_TMP/incidents.json"
_restore_state
assert_eq "restore-no-clobber" "$(jq -r '.[0].ts' "$ECLIPVPN_TMP/incidents.json")" "99"
# nothing mirrored yet -> restore must not create an empty/garbage file
rm -rf "$MIRROR"; rm -f "$ECLIPVPN_TMP/last_switch.json"
_restore_state
assert_eq "restore-nomirror" "$([ -f "$ECLIPVPN_TMP/last_switch.json" ] && echo yes || echo no)" no

# UPGRADE case: a journal already in /tmp with no mirror yet must be SEEDED,
# not left to die at the next reboot. This is what preserves the history that
# predates the feature — including the incident that motivated it.
rm -rf "$MIRROR"
echo '[{"ts":7,"type":"preexisting"}]' > "$ECLIPVPN_TMP/incidents.json"
_restore_state
assert_eq "seed-mirror" "$(jq -r '.[0].type' "$MIRROR/incidents.json" 2>/dev/null)" "preexisting"
# an existing mirror is authoritative history: a truncated /tmp must not win
echo '[{"ts":8,"type":"mirrored"}]' > "$MIRROR/incidents.json"
echo '[]' > "$ECLIPVPN_TMP/incidents.json"
_restore_state
assert_eq "seed-no-overwrite" "$(jq -r '.[0].type' "$MIRROR/incidents.json" 2>/dev/null)" "mirrored"

_t log_incident_mirrors
rm -rf "$MIRROR"; rm -f "$ECLIPVPN_TMP/incidents.json" "$ECLIPVPN_TMP/op.in_progress"
_log_incident "check_fail" "1.2.3.4" "srv" "boom"
assert_eq "incident-written"  "$(jq -r '.[-1].type' "$ECLIPVPN_TMP/incidents.json" 2>/dev/null)" "check_fail"
assert_eq "incident-mirrored" "$(jq -r '.[-1].detail' "$MIRROR/incidents.json" 2>/dev/null)" "boom"
# the mirror must track subsequent appends, not just the first write
_log_incident "auto_switch" "5.6.7.8" "srv2" "second"
assert_eq "incident-mirror-2" "$(jq -r 'length' "$MIRROR/incidents.json" 2>/dev/null)" "2"

_t record_switch_mirrors
printf '%s\n' '[{"name":"A"},{"name":"B"}]' > "$ECLIPVPN_TMP/servers.json"
rm -f "$ECLIPVPN_TMP/last_switch.json"
_record_switch 0 1 failover
assert_eq "switch-written"  "$(jq -r '.to' "$ECLIPVPN_TMP/last_switch.json" 2>/dev/null)" "B"
assert_eq "switch-mirrored" "$(jq -r '.reason' "$MIRROR/last_switch.json" 2>/dev/null)" "failover"

rm -rf "$MIRROR"
