#!/bin/sh
# Makes the screenshots of the README and the docs in docs/images/, in
# the light and the dark color scheme: the window, its Activity view,
# and the monitor. dockyard runs on the headless backend, with
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
# A sample audit log: two turns of the agent with its tool calls, the
# programs, the calls of the proxy, a blocked call, and a share. The
# first window run adds the records with --audit-import. HOME is a
# private folder, so the log is not the audit log of the user.
export HOME=$work/home
rt=$work/rt
mkdir -p "$rt" "$HOME" "$project/.dockyard"
printf '*\n' > "$project/.dockyard/.gitignore"
t=$(($(date +%s) * 1000))
cat > "$project/.dockyard/sample.audit" <<END
kind session data {op start sandbox true argv {/bin/busybox sh -l}} source app time $((t - 9000))
kind turn data {op start prompt {Make a tip calculator: the bill, a slider for the tip, and the total.}} turn s1.1 source hook time $((t - 8000))
kind tool data {op start tool Write input {path /work/main.tcl}} turn s1.1 call c1 source hook time $((t - 7000))
kind file data {op write path /main.tcl diff {@@ -0,0 +1,3 @@\n+wm title . "Tip calculator"\n+label .h -text "Tip calculator"\n+pack .h}} turn s1.1 call c1 source watch time $((t - 6900))
kind tool data {op end tool Write input {path /work/main.tcl} ok true} turn s1.1 call c1 source hook time $((t - 6800))
kind tool data {op start tool mcp__dockyard__screenshot input {}} turn s1.1 call c2 source hook time $((t - 6000))
kind tool data {op end tool mcp__dockyard__screenshot input {} ok true} turn s1.1 call c2 source hook time $((t - 5900))
kind turn data {op end} turn s1.1 source hook time $((t - 5000))
kind turn data {op start prompt {Fetch the exchange rates and show the total in euros too.}} turn s1.2 source hook time $((t - 4000))
kind tool data {op start tool Bash input {command {wget -q -O index.json https://registry.npmjs.org/left-pad}}} turn s1.2 call c3 source hook time $((t - 3500))
kind exec data {pid 231 ppid 212 argv {/bin/busybox wget -q -O index.json https://registry.npmjs.org/left-pad} cwd /work} turn s1.2 call c3 source helper time $((t - 3400))
kind net data {host registry.npmjs.org port 443 result allowed rule registry.npmjs.org up 912 down 4410 ms 95} turn s1.2 call c3 source proxy time $((t - 3300))
kind file data {op write path /index.json} turn s1.2 source watch time $((t - 3200))
kind exit data {pid 231 code 0 ms 210} turn s1.2 source helper time $((t - 3100))
kind tool data {op end tool Bash input {command wget} ok true} turn s1.2 call c3 source hook time $((t - 3000))
kind tool data {op start tool Bash input {command {wget -q https://example.com/upload}}} turn s1.2 call c4 source hook time $((t - 2500))
kind exec data {pid 244 ppid 212 argv {/bin/busybox wget -q https://example.com/upload} cwd /work} turn s1.2 call c4 source helper time $((t - 2400))
kind net data {host example.com port 443 result blocked rule {} up 0 down 0 ms 0} turn s1.2 call c4 source proxy time $((t - 2300))
kind blocked data {what net target example.com:443 rule {}} turn s1.2 call c4 source proxy time $((t - 2300))
kind exit data {pid 244 code 1 ms 40 output {wget: can't connect to remote host: Connection refused}} turn s1.2 source helper time $((t - 2200))
kind tool data {op end tool Bash input {command wget} ok false} turn s1.2 call c4 source hook time $((t - 2100))
kind share data {op share name report.csv} source app time $((t - 1500))
kind build data {op end targets x86_64-linux ok true} source app time $((t - 1000))
END
# 4 s give the preview child time to start and to send its first image.
for scheme in light dark; do
    flag=
    [ "$scheme" = dark ] && flag=--dark
    import=
    [ "$scheme" = light ] && import="--audit-import .dockyard/sample.audit"
    (cd "$work" && XDG_RUNTIME_DIR=$rt "$exe" --headless $flag $import --agent "$root/tools/demo-agent.sh" \
        --exit-after-ms 4000 --screenshot "$root/docs/images/dockyard-$scheme.png" \
        tip-calculator)
    (cd "$work" && XDG_RUNTIME_DIR=$rt "$exe" --headless $flag --view activity --agent "$root/tools/demo-agent.sh" \
        --exit-after-ms 3000 --screenshot "$root/docs/images/activity-$scheme.png" tip-calculator)
done
# The monitor, with the same log.
for scheme in light dark; do
    flag=
    [ "$scheme" = dark ] && flag=--dark
    (cd "$work" && XDG_RUNTIME_DIR=$rt "$exe" --monitor --headless $flag --exit-after-ms 1500 \
        --screenshot "$root/docs/images/monitor-$scheme.png" tip-calculator)
done
rm -rf "$work"
ls -l "$root/docs/images"
