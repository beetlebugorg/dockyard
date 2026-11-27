#!/bin/sh
# Makes the tools disk of the sandbox guest for one architecture (ARCH
# arm64 or x86_64), on a Linux host of that architecture with Docker:
#   out/ARCH-tools.img    a squashfs of the pane programs (node, npm, git,
#                         Zig, and dockyard-guest), with its dm-verity hash
#                         tree after the data
#   out/ARCH-tools.json   the disk entry for manifest.sh
#   out/ARCH-packages.txt the Alpine packages and their versions
# Needs Zig 0.17.0 for the helper. The image of Alpine and the archive of
# Zig are pinned by SHA-256.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
top=$(cd "$here/../.." && pwd)
out=${OUT:-$here/out}
arch=${ARCH:-x86_64}
alpine=alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
zig_version=0.17.0
case $arch in
    x86_64) zt=x86_64 zig_sha=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 platform=linux/amd64 ;;
    arm64) zt=aarch64 zig_sha=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8 platform=linux/arm64 ;;
    *) echo "ARCH must be arm64 or x86_64" >&2; exit 2 ;;
esac
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/in" "$work/out"
(cd "$work" && ${ZIG:-zig} build-exe -target $zt-linux-musl -OReleaseSmall -fstrip -fsingle-threaded \
    "$top/src/guest/main.zig" --name dockyard-guest -femit-bin="$work/in/dockyard-guest")
zig_tar=${ZIG_TARBALL:-}
if [ -z "$zig_tar" ]; then
    zig_tar=$work/in/zig.tar.xz
    curl -fsSL -o "$zig_tar" "https://ziglang.org/download/$zig_version/zig-$zt-linux-$zig_version.tar.xz"
else
    cp "$zig_tar" "$work/in/zig.tar.xz"
fi
cp "$here/rootfs.sh" "$work/in/rootfs.sh"
# A fixed salt keeps the build reproducible.
salt=$(printf 'dockyard-tools-%s' "$arch" | sha256sum | cut -c1-64)
docker run --rm --platform "$platform" -v "$work/in:/in:ro" -v "$work/out:/out" "$alpine" \
    sh /in/rootfs.sh "$arch" "$zig_sha" "$salt"
hash=$(sed -n 's/^Root hash:[[:space:]]*//p' "$work/out/verity.txt")
[ ${#hash} -eq 64 ] || { echo "no root hash" >&2; exit 1; }
blocks=$(cat "$work/out/blocks.txt")
img=$out/$arch-tools.img
cp "$work/out/tools.img" "$img"
cp "$work/out/packages.txt" "$out/$arch-packages.txt"
sum=$(sha256sum "$img" | cut -c1-64)
cat > "$out/$arch-tools.json" <<JSON
{"name":"tools","file":"$arch-tools.img","sha256":"$sum","size":$(stat -c %s "$img"),"read_only":true,"verity":{"root_hash":"$hash","salt":"$salt","data_block":4096,"hash_block":4096,"hash_offset":$(( blocks * 4096 ))}}
JSON
echo "$arch: tools.img $sum, $(stat -c %s "$img") bytes"
echo "$arch: verity root hash $hash"
