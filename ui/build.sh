#!/bin/sh
# Assemble ui/{index.html,style.css,app.js} into the single shipped file
# www/eclipvpn/index.html (committed). Edit ui/, never the output.
#   sh ui/build.sh           build
#   sh ui/build.sh --check   exit 1 if the committed output is stale (CI, deploy)
#
# One file on purpose: released self-updaters install exactly one UI file, and
# a page cached apart from its script/style would break after an update.
set -eu
cd "$(dirname "$0")"
OUT=../www/eclipvpn/index.html
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
for f in index.html style.css app.js; do
    [ -s "$f" ] || { echo "ERROR: ui/$f is missing or empty" >&2; exit 1; }
done
awk '/^@@include /{ while ((getline l < $2) > 0) print l; close($2); next } { print }' index.html > "$TMP"
if [ "${1:-}" = --check ]; then
    cmp -s "$TMP" "$OUT" || { echo "ERROR: www/eclipvpn/index.html is out of sync with ui/ - run: sh ui/build.sh" >&2; exit 1; }
else
    cat "$TMP" > "$OUT"
    echo "built www/eclipvpn/index.html"
fi
