# Self-update (update.sh): version compare, release-tree validation, and the
# full backup → install → health → rollback cycle against a scratch install
# root (ECLIPVPN_ROOT). Network, VPN restart and the health probe are stubbed.

# --- _ver_gt ---
_t ver_gt
_ver_gt v2026.07 2026.06;      assert_rc "vg-newer-month"  "$?" 0
_ver_gt v2026.06.1 2026.06;    assert_rc "vg-patch"        "$?" 0
_ver_gt v2026.06 2026.06;      assert_rc "vg-equal"        "$?" 1
_ver_gt v2026.06 2026.06.0;    assert_rc "vg-equal-pad"    "$?" 1
_ver_gt v2026.05.9 2026.06;    assert_rc "vg-older"        "$?" 1
_ver_gt v2026.10 2026.9;       assert_rc "vg-numeric"      "$?" 0
_ver_gt v2027.01 2026.12;      assert_rc "vg-year"         "$?" 0
_ver_gt vbeta 2026.06;         assert_rc "vg-garbage"      "$?" 1
_ver_gt v2026.06-rc1 2026.06;  assert_rc "vg-suffix"       "$?" 1

# --- build a fake release tree (+tarball) from the working tree ---
UPD="$ECLIPVPN_TMP/upd_test"
rm -rf "$UPD"; mkdir -p "$UPD/src/flowvpn-9999.1" "$UPD/root/etc/eclipvpn"
REL="$UPD/src/flowvpn-9999.1"
for f in packaging/ship-files www/eclipvpn/index.html $(grep -v '^#' "$REPO/packaging/ship-files" | grep -v '^ *$'); do
    mkdir -p "$REL/$(dirname "$f")"; cp "$REPO/$f" "$REL/$f"
done
sed 's/^ECLIPVPN_VERSION="[^"]*"/ECLIPVPN_VERSION="9999.1"/' "$REPO/usr/bin/eclipvpn" > "$REL/usr/bin/eclipvpn"
( cd "$UPD/src" && tar czf "$UPD/release.tar.gz" flowvpn-9999.1 )

# --- _update_validate ---
_t update_validate
assert_eq "uv-version"      "$(_update_tree_version "$REL")" 9999.1
_update_validate "$REL" >/dev/null;  assert_rc "uv-ok"  "$?" 0
cp -R "$REL" "$UPD/bad"
printf 'if then fi (\n' >> "$UPD/bad/usr/lib/eclipvpn/parse.sh"
assert_eq "uv-syntax" "$(_update_validate "$UPD/bad")" "синтаксическая ошибка в usr/lib/eclipvpn/parse.sh"
rm -rf "$UPD/bad"; cp -R "$REL" "$UPD/bad"; rm "$UPD/bad/usr/lib/eclipvpn/xray.sh"
assert_eq "uv-missing"  "$(_update_validate "$UPD/bad")" "нет файла usr/lib/eclipvpn/xray.sh"
rm -rf "$UPD/bad"; cp -R "$REL" "$UPD/bad"; echo "../../etc/passwd" >> "$UPD/bad/packaging/ship-files"
_update_validate "$UPD/bad" >/dev/null; assert_rc "uv-traversal" "$?" 1
rm -rf "$UPD/bad"; cp -R "$REL" "$UPD/bad"; rm "$UPD/bad/www/eclipvpn/index.html"
_update_validate "$UPD/bad" >/dev/null; assert_rc "uv-no-ui" "$?" 1
rm -rf "$UPD/bad"

# --- full worker cycle on a scratch root (stubbed restart + health) ---
_t update_cycle
export ECLIPVPN_ROOT="$UPD/root"
# "Installed" old version: every file present except update.sh (new in the release).
for f in $(_update_files "$REL"); do
    [ "$f" = "usr/lib/eclipvpn/update.sh" ] && continue
    mkdir -p "$ECLIPVPN_ROOT/$(dirname "$f")"; echo "OLD $f" > "$ECLIPVPN_ROOT/$f"
done
echo "oldsha 2026-01-01 via=deploy.sh" > "$ECLIPVPN_ROOT/etc/eclipvpn/build"
UPD_CALLS="$UPD/calls"; : > "$UPD_CALLS"
_update_restart()  { echo restart >> "$UPD_CALLS"; }
_update_drop_old() { echo drop_old >> "$UPD_CALLS"; }
_log_incident()    { echo "inc:$1" >> "$UPD_CALLS"; }
_build_id()        { echo "oldsha"; }

# Healthy after restart ⇒ done, new files in place, build stamped.
fresh_config '{"running_intent":true}'
_update_healthy() { return 0; }
mkdir -p "$ECLIPVPN_TMP/update.lockdir"
_self_update_run local "$UPD/release.tar.gz"; assert_rc "uc-ok-rc" "$?" 0
assert_json "uc-ok-phase"   "$(cmd_update_status)" '.phase' done
assert_eq   "uc-ok-new"     "$(cmp -s "$REL/usr/bin/eclipvpn" "$ECLIPVPN_ROOT/usr/bin/eclipvpn" && echo same)" same
assert_eq   "uc-ok-added"   "$([ -s "$ECLIPVPN_ROOT/usr/lib/eclipvpn/update.sh" ] && echo yes)" yes
assert_eq   "uc-ok-ui"      "$(cmp -s "$REL/www/eclipvpn/index.html" "$ECLIPVPN_ROOT/www/eclipvpn/index.html" && echo same)" same
assert_eq   "uc-ok-mode"    "$(ls -l "$ECLIPVPN_ROOT/usr/bin/eclipvpn" | cut -c4)" x
assert_eq   "uc-ok-build"   "$(cut -d' ' -f1,3 "$ECLIPVPN_ROOT/etc/eclipvpn/build")" "local via=self-update"
assert_eq   "uc-ok-calls"   "$(tr '\n' ' ' < "$UPD_CALLS")" "restart inc:update "
assert_eq   "uc-ok-unlock"  "$([ -d "$ECLIPVPN_TMP/update.lockdir" ] && echo held || echo free)" free
assert_eq   "uc-prev-saved" "$(cat "$(_update_prev_dir)/usr/bin/eclipvpn")" "OLD usr/bin/eclipvpn"

# Reset the root to "old" and make the tunnel fail ⇒ rolled back, old files back,
# the file that only the new release had is removed, build stamp restored.
for f in $(_update_files "$REL"); do
    [ "$f" = "usr/lib/eclipvpn/update.sh" ] && { rm -f "$ECLIPVPN_ROOT/$f"; continue; }
    echo "OLD $f" > "$ECLIPVPN_ROOT/$f"
done
echo "oldsha 2026-01-01 via=deploy.sh" > "$ECLIPVPN_ROOT/etc/eclipvpn/build"
: > "$UPD_CALLS"
_update_healthy() { return 1; }
mkdir -p "$ECLIPVPN_TMP/update.lockdir"
_self_update_run local "$UPD/release.tar.gz"; assert_rc "uc-rb-rc" "$?" 1
assert_json "uc-rb-phase"   "$(cmd_update_status)" '.phase' rolled_back
assert_eq   "uc-rb-old"     "$(cat "$ECLIPVPN_ROOT/usr/bin/eclipvpn")" "OLD usr/bin/eclipvpn"
assert_eq   "uc-rb-ui"      "$(cat "$ECLIPVPN_ROOT/www/eclipvpn/index.html")" "OLD www/eclipvpn/index.html"
assert_eq   "uc-rb-newgone" "$([ -e "$ECLIPVPN_ROOT/usr/lib/eclipvpn/update.sh" ] && echo present || echo gone)" gone
assert_eq   "uc-rb-build"   "$(cat "$ECLIPVPN_ROOT/etc/eclipvpn/build")" "oldsha 2026-01-01 via=deploy.sh"
assert_eq   "uc-rb-calls"   "$(tr '\n' ' ' < "$UPD_CALLS")" "restart restart inc:update_rollback "

# VPN deliberately off ⇒ install, never restart (init.d restart would switch it on).
: > "$UPD_CALLS"; fresh_config '{"running_intent":false}'
mkdir -p "$ECLIPVPN_TMP/update.lockdir"
_self_update_run local "$UPD/release.tar.gz"
assert_eq   "uc-off-calls"  "$(tr '\n' ' ' < "$UPD_CALLS")" "drop_old inc:update "

# A corrupt tarball is rejected before anything is touched.
echo "OLD usr/bin/eclipvpn" > "$ECLIPVPN_ROOT/usr/bin/eclipvpn"
echo garbage > "$UPD/broken.tar.gz"; : > "$UPD_CALLS"
mkdir -p "$ECLIPVPN_TMP/update.lockdir"
_self_update_run local "$UPD/broken.tar.gz"; assert_rc "uc-bad-rc" "$?" 1
assert_json "uc-bad-phase"  "$(cmd_update_status)" '.phase' failed
assert_eq   "uc-bad-untouched" "$(cat "$ECLIPVPN_ROOT/usr/bin/eclipvpn")" "OLD usr/bin/eclipvpn"
assert_eq   "uc-bad-calls"  "$(cat "$UPD_CALLS")" ""

# --- the journal entry survives a held op.in_progress ---
_t update_journal
: > "$UPD_CALLS"
# Marker owned by a dead pid ⇒ logged at once (no 30s wait).
echo 999999 > "$ECLIPVPN_TMP/op.in_progress"
_update_journal update_rollback "x"
assert_eq "uj-stale-marker" "$(cat "$UPD_CALLS")" "inc:update_rollback"
# Marker owned by a live process that exits ⇒ waits, then logs.
: > "$UPD_CALLS"
( exec sleep 2 ) & _hold=$!
echo "$_hold" > "$ECLIPVPN_TMP/op.in_progress"
_update_journal update "y"
assert_eq "uj-waited" "$(cat "$UPD_CALLS")" "inc:update"
rm -f "$ECLIPVPN_TMP/op.in_progress"

# --- update-check / self-update entry points (GitHub stubbed) ---
_t update_check
_router_fetch() { printf '%s' '{"tag_name":"v9999.2","published_at":"2026-12-01T00:00:00Z","body":"notes","html_url":"https://x"}' > "$2"; }
assert_json "ck-available" "$(cmd_update_check)" '.available' true
assert_json "ck-latest"    "$(cmd_update_check)" '.latest' v9999.2
_router_fetch() { printf '%s' "{\"tag_name\":\"v$ECLIPVPN_VERSION\"}" > "$2"; }
assert_json "ck-current"   "$(cmd_update_check)" '.available' false
assert_json "su-uptodate"  "$(cmd_self_update)" '.status' up_to_date
_router_fetch() { return 22; }
cmd_update_check >/dev/null 2>&1; assert_rc "ck-offline" "$?" 1
cmd_self_update 'v1;rm' >/dev/null 2>&1; assert_rc "su-bad-tag" "$?" 1
cmd_self_update 'latest' >/dev/null 2>&1; assert_rc "su-bad-tag2" "$?" 1

# --- cleanup + restore real functions ---
unset ECLIPVPN_ROOT
rm -rf "$UPD" "$ECLIPVPN_TMP/update_state.json" "$ECLIPVPN_TMP/update.lockdir" "$(_update_prev_dir)"
# shellcheck disable=SC1090
. "$REPO/usr/bin/eclipvpn"
