#!/bin/sh
# Tests the skill zip as a sandbox with no display uses it: unzip, then
# dockyard new, run, check, and build for x86_64-linux and
# x86_64-windows. No agent program runs.
#
# usage: tools/skill-test.sh [SKILL.zip]   (default: zig-out/dockyard-app.zip)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
zip=${1:-$root/zig-out/dockyard-app.zip}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
unzip -q "$zip"
cli=$work/dockyard-app/bin/dockyard
# The display variables stay out, as in a sandbox.
unset WAYLAND_DISPLAY DISPLAY || true
"$cli" new counter >/dev/null
cat >counter/main.tcl <<'TCL'
set n 0
ttk::button .go -text Count -command {incr ::n}
ttk::label .count -textvariable n
pack .go .count -padx 12 -pady 8
TCL
"$cli" run counter >/dev/null
[ -s counter/shot.png ] || { echo "FAIL: no screenshot"; exit 1; }
awk '/^```tcl/{on=1;next} on&&/^```/{exit} on' "$work/dockyard-app/SKILL.md" >check.tcl
got=$("$cli" check counter check.tcl)
[ "$got" = "n = 1" ] || { echo "FAIL: the check printed: $got"; exit 1; }
"$cli" build counter x86_64-linux x86_64-windows 2>&1 | sed 's|^.*/counter/|counter/|'
[ -x counter/build/x86_64-linux/counter ] || { echo "FAIL: no Linux program"; exit 1; }
[ -s counter/build/x86_64-windows/counter.exe ] || { echo "FAIL: no Windows program"; exit 1; }
echo "ok: new, run, check, and build"
