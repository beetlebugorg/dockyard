#!/bin/sh
# Makes docs/images/dockyard-demo.gif, the short animation of the README:
# the request in the terminal pane, the first run of the app in the
# preview, and the checked app. Each frame is one headless run of
# dockyard (--headless --screenshot), with tools/demo-agent.sh at one
# stage of its session and main.tcl of that stage. No window opens on
# the desktop. magick joins the frames.
#
# usage: tools/capture.sh [path of the dockyard program]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
exe=${1:-$root/zig-out/bin/dockyard}
work=/tmp/dockyard
project=$work/tip-calculator
frames=$work/frames
rm -rf "$work"
mkdir -p "$project" "$frames"
git -C "$project" init -q
shot() { # stage, main.tcl or "", output
    rm -f "$project/main.tcl"
    [ -n "$2" ] && cp "$2" "$project/main.tcl"
    printf '#!/bin/sh\nDEMO_STAGE=%s exec "%s"\n' "$1" "$root/tools/demo-agent.sh" > "$work/agent.sh"
    chmod +x "$work/agent.sh"
    (cd "$work" && "$exe" --headless --agent "$work/agent.sh" \
        --exit-after-ms 4000 --screenshot "$3" tip-calculator)
}
sed 's/^set ::bill 84.00$/set ::bill ""/' "$root/tools/demo-app.tcl" > "$work/empty-bill.tcl"
shot 1 "" "$frames/1.png"
shot 2 "$work/empty-bill.tcl" "$frames/2.png"
shot 3 "$root/tools/demo-app.tcl" "$frames/3.png"
magick -delay 160 "$frames/1.png" -delay 200 "$frames/2.png" -delay 400 "$frames/3.png" \
    -layers Optimize -loop 0 "$root/docs/images/dockyard-demo.gif"
rm -rf "$work"
ls -l "$root/docs/images/dockyard-demo.gif"
