#!/bin/sh
# Makes the mockups of docs/dev/design.md in docs/dev/images/: each view
# of tools/mockup.tcl in the light and the dark color scheme. The script
# runs in the preview child of dockyard on the headless backend, so no
# window opens on the desktop.
#
# usage: tools/mockups.sh [path of the dockyard program]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
exe=${1:-$root/zig-out/bin/dockyard}
work=$(mktemp -d)
mkdir -p "$root/docs/dev/images"
cp "$root/tools/mockup.tcl" "$root/src/ui/theme.tcl" "$root/src/ui/ui-icons.tcl" "$root/src/ui/icon.tcl" "$work/"
for view in ${VIEWS:-main build first apps activity}; do
    echo "$view" > "$work/view.txt"
    for scheme in light dark; do
        flag=
        [ "$scheme" = dark ] && flag=--dark
        rm -f "$work/shot.png"
        "$exe" --run "$work/mockup.tcl" --headless $flag --exit-after-ms 30000 || echo "failed: $view $scheme"
        cp "$work/shot.png" "$root/docs/dev/images/design-$view-$scheme.png"
    done
done
rm -rf "$work"
