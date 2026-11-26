#!/bin/sh
# Makes the screenshots of the README in docs/images/, in the light and
# the dark color scheme. dockyard runs on the headless backend, with
# tools/demo-agent.sh as the agent program and tools/demo-app.tcl as
# main.tcl of a new project.
#
# usage: tools/screenshots.sh [path of the dockyard program]
# The default program is zig-out/bin/dockyard. A ReleaseFast build
# makes the preview image faster.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
exe=${1:-$root/zig-out/bin/dockyard}
work=/tmp/dockyard-shots
project=$work/tip-calculator
rm -rf "$work"
mkdir -p "$project" "$root/docs/images"
cp "$root/tools/demo-app.tcl" "$project/main.tcl"
git -C "$project" init -q
# 4 s give the preview child time to start and to send its first image.
for scheme in light dark; do
    flag=
    [ "$scheme" = dark ] && flag=--dark
    (cd "$work" && "$exe" --headless $flag --agent "$root/tools/demo-agent.sh" \
        --exit-after-ms 4000 --screenshot "$root/docs/images/dockyard-$scheme.png" \
        tip-calculator)
done
rm -rf "$work"
ls -l "$root/docs/images"
