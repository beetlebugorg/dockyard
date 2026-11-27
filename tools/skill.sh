#!/bin/sh
# Makes the skill zip of issue 16: skill/dockyard-app with the ztk
# programs of all the targets in runtimes/. Checks the size of the zip
# against the upload limit of 30,000,000 bytes.
#
# usage: tools/skill.sh [OUT.zip]   (default: zig-out/dockyard-app.zip)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/zig-out/dockyard-app.zip}
limit=30000000
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# One zig build for each target, so the build fits in 4 GB.
for t in x86_64-linux aarch64-linux x86_64-macos aarch64-macos x86_64-windows aarch64-windows; do
    (cd "$root" && zig build runtimes -Druntimes=$t -Dstatic-runtimes=true -p "$work/prefix")
done
cp -R "$root/skill/dockyard-app" "$work/dockyard-app"
mkdir -p "$work/dockyard-app/runtimes"
for d in "$work/prefix/lib/ztk/runtime"/*; do
    t=$(basename "$d")
    mkdir -p "$work/dockyard-app/runtimes/$t"
    for f in "$d"/ztk "$d"/ztk.exe; do
        [ -f "$f" ] && cp "$f" "$work/dockyard-app/runtimes/$t/"
    done
done
rm -f "$out"
mkdir -p "$(dirname "$out")"
(cd "$work" && zip -q -r -9 "$out" dockyard-app)
size=$(wc -c <"$out")
echo "$out: $size bytes (limit $limit)"
for t in "$work/dockyard-app/runtimes"/*; do
    echo "  $(basename "$t"): $(cat "$t"/* | wc -c) bytes"
done
[ "$size" -le "$limit" ] || { echo "the skill zip is over the limit" >&2; exit 1; }
