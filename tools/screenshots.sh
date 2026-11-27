#!/bin/sh
# Makes the screenshots of the README and the docs in docs/images/, in
# the light and the dark color scheme: the window and the monitor. dockyard runs on the headless backend, with
# tools/demo-agent.sh as the agent program and tools/demo-app.tcl as
# main.tcl of a new project.
#
# usage: tools/screenshots.sh [path of the dockyard program]
# The default program is zig-out/bin/dockyard. A ReleaseFast build
# makes the preview image faster.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
exe=${1:-$root/zig-out/bin/dockyard}
work=/tmp/dockyard
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
# The monitor, with a sample log: the programs, the calls of the proxy,
# and the shares of a short session in the guest. The log is the file of
# the project in a private XDG_RUNTIME_DIR.
rt=$work/rt
mkdir -p "$rt"
hash=$(cd "$root" && zig run tools/project-hash.zig -- "$project")
log=$rt/dockyard-$hash.monitor
t=$(($(date +%s) * 1000))
cat > "$log" <<END
kind exec time $t pid 212 ppid 1 argv {/bin/busybox sh -l}
kind exec time $((t + 2100)) pid 231 ppid 212 argv {/bin/busybox wget -q -O index.json https://registry.npmjs.org/left-pad}
kind net time $((t + 2300)) host registry.npmjs.org port 443 result allowed up 912 down 4410 ms 95
kind file time $((t + 2500)) op write path /index.json
kind exec time $((t + 6100)) pid 244 ppid 212 argv {/bin/busybox wget -q https://example.com/upload}
kind net time $((t + 6200)) host example.com port 443 result blocked up 0 down 0 ms 0
kind share time $((t + 9000)) op share name report.csv
kind exec time $((t + 9800)) pid 251 ppid 212 argv {/bin/busybox wc -l /inbox/report.csv}
kind share time $((t + 12000)) op export name summary.txt
kind file time $((t + 12100)) op write path /exports/summary.txt
END
chmod 600 "$log"
for scheme in light dark; do
    flag=
    [ "$scheme" = dark ] && flag=--dark
    (cd "$work" && XDG_RUNTIME_DIR=$rt "$exe" --monitor --headless $flag --exit-after-ms 1500 \
        --screenshot "$root/docs/images/monitor-$scheme.png" tip-calculator)
done
rm -rf "$work"
ls -l "$root/docs/images"
