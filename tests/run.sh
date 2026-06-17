#!/bin/sh
# EclipVPN unit tests. Sources the REAL code (usr/bin/eclipvpn with
# ECLIPVPN_SOURCE_ONLY=1, so init + the dispatch case are skipped) against a
# throwaway scratch dir — no copies of functions, no install needed. Tests the
# pure parsers, the input validators, and the lock / config-write primitives.
#
# Requires jq and a shell with `local` (busybox ash or bash). There is no build
# step in this project, so the suite is the only automated regression net.
#
#   sh tests/run.sh                 # run every suite
#   sh tests/run.sh parse config    # run only test_parse.sh / test_config.sh
#
# On the router (no jq on the Windows dev box):
#   tar c usr tests | ssh root@ROUTER \
#     'rm -rf /tmp/eclvt && mkdir -p /tmp/eclvt && cd /tmp/eclvt && tar x && sh tests/run.sh'

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found — the suite needs jq"; exit 2; }

# Scratch sandbox — every test points ECLIPVPN_TMP/CONFIG here, never at the
# installed /etc or /tmp paths.
TESTROOT="${TMPDIR:-/tmp}/eclv_test.$$"
mkdir -p "$TESTROOT/tmp"
export ECLIPVPN_LIB="$REPO/usr/lib/eclipvpn"
export ECLIPVPN_TMP="$TESTROOT/tmp"
export ECLIPVPN_CONFIG="$TESTROOT/config.json"
export ECLIPVPN_SOURCE_ONLY=1

# Load the real functions (all libs + the core helpers in the dispatcher),
# stopping before config init / the dispatch case via the SOURCE_ONLY guard.
# shellcheck disable=SC1090
. "$REPO/usr/bin/eclipvpn"

# ISOLATION GUARD — a sourced lib must NOT clobber the scratch paths we exported.
# network.sh once had a BARE `ECLIPVPN_CONFIG=/etc/eclipvpn/config.json` at top
# level that overrode our override, so `sh tests/run.sh` wrote to the LIVE
# config and stubbed prod twice (2026-06-17). Refuse to run a single test if any
# sandbox path escaped to a real /etc or /tmp location — a wrong test is far
# better than a wiped production config.
for _v in ECLIPVPN_CONFIG ECLIPVPN_TMP ECLIPVPN_LIB; do
    eval "_pv=\$$_v"
    case "$_pv" in
        "$TESTROOT"/*|"$REPO"/*) ;;
        *) echo "FATAL: $_v escaped the sandbox -> '$_pv' (a sourced lib clobbered it). Refusing to run against live paths."; exit 3 ;;
    esac
done

PASS=0; FAIL=0; CUR="-"
_t()  { CUR="$1"; }
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL [$CUR] $1"; }

# assert_eq LABEL ACTUAL EXPECTED
assert_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: got [$2] want [$3]"; fi; }
# assert_rc LABEL ACTUAL_RC EXPECTED_RC
assert_rc() { if [ "$2" = "$3" ]; then ok; else bad "$1: rc=$2 want $3"; fi; }
# assert_json LABEL JSON JQFILTER EXPECTED
assert_json() {
    local got; got=$(printf '%s' "$2" | jq -r "$3" 2>/dev/null)
    if [ "$got" = "$4" ]; then ok; else bad "$1: ($3)=[$got] want [$4]"; fi
}

# Write a known config.json for tests that mutate it.
fresh_config() { printf '%s' "$1" > "$ECLIPVPN_CONFIG"; }

# Pick suites: args -> test_<arg>.sh; no args -> all test_*.sh
suites=""
if [ "$#" -gt 0 ]; then
    for a in "$@"; do suites="$suites $REPO/tests/test_$a.sh"; done
else
    suites=$(ls "$REPO"/tests/test_*.sh 2>/dev/null)
fi

for s in $suites; do
    [ -f "$s" ] || { echo "skip: $(basename "$s") (not found)"; continue; }
    echo "== $(basename "$s") =="
    # shellcheck disable=SC1090
    . "$s"
done

echo
echo "RESULT pass=$PASS fail=$FAIL"
rm -rf "$TESTROOT"
[ "$FAIL" -eq 0 ]
