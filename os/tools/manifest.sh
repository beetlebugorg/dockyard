#!/bin/sh
# Writes the signed release of the dockyard guest in out/: the kernel and
# the root disk of a ztcl guest release (ZTCL_IMAGE, a folder with its
# manifest.json and files), and the disks of build.sh after the root disk
# of each architecture. DISKS names them: "claude" (default) for the
# release of the pane, "claude build" for the release with Zig. The
# command line maps disk N (/dev/vdb, /dev/vdc) as the dm-verity device
# /dev/dm-N: the Claude Code disk is /dev/dm-1, and the build disk is
# /dev/dm-2.
#   sh manifest.sh                     signs with the test key, name dockyard-guest-test
#   DISKS="claude build" sh manifest.sh   name dockyard-guest-build-test
# The private half of the test key is in the repository: anyone can sign
# with it, so it signs only a name that ends in -test.
#   KEY=path NAME=dockyard-guest sh manifest.sh   signs with a release key
# The disks of build.sh are in IN (default: out). The counter is the
# commit time of HEAD, so it grows on main.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$here/out}
in=${IN:-$out}
disks=${DISKS:-claude}
src=${ZTCL_IMAGE:?ZTCL_IMAGE is the folder of a ztcl guest release}
key=${KEY:-$here/testkey/test_ed25519}
case $disks in
    claude) default_name=dockyard-guest-test ;;
    "claude build") default_name=dockyard-guest-build-test ;;
    *) echo "DISKS must be \"claude\" or \"claude build\"" >&2; exit 2 ;;
esac
name=${NAME:-$default_name}
mkdir -p "$out"
version=${VERSION:-0.1.0}
counter=${COUNTER:-$(git -C "$here" log -1 --format=%ct)}
archs='{}'
for arch in x86_64 arm64; do
    [ -f "$in/$arch-claude.json" ] || continue
    base=$(jq -c --arg a "$arch" '.archs[$a] // empty' "$src/manifest.json")
    [ -n "$base" ] || { echo "$arch: not in $src/manifest.json" >&2; exit 1; }
    cmdline=$(echo "$base" | jq -r .cmdline)
    case $cmdline in *'dm-mod.waitfor=/dev/vda '*'dm-mod.create="'*'"'*) ;;
        *) echo "$arch: the command line has no dm-verity root" >&2; exit 1 ;; esac
    entry=$base
    wait=/dev/vda
    n=1
    for disk in $disks; do
        d=$(cat "$in/$arch-$disk.json")
        dev=/dev/vd$(echo bcdefgh | cut -c$n)
        blocks=$(( $(echo "$d" | jq .verity.hash_offset) / 4096 ))
        hash=$(echo "$d" | jq -r .verity.root_hash)
        salt=$(echo "$d" | jq -r .verity.salt)
        table="0 $(( blocks * 8 )) verity 1 $dev $dev 4096 4096 $blocks $blocks sha256 $hash $salt"
        wait=$wait,$dev
        # Each device goes after the one before it in dm-mod.create, with ";".
        cmdline=$(printf '%s' "$cmdline" | sed "s|\\(dm-mod.create=\"[^\"]*\\)\"|\\1;$disk,,,ro,$table\"|")
        entry=$(echo "$entry" | jq -c --argjson t "$d" '.disks += [$t]')
        cp "$in/$arch-$disk.img" "$out/"
        n=$(( n + 1 ))
    done
    cmdline=$(printf '%s' "$cmdline" | sed "s|dm-mod.waitfor=/dev/vda |dm-mod.waitfor=$wait |")
    entry=$(echo "$entry" | jq -c --arg c "$cmdline" '.cmdline = $c')
    for f in $(echo "$base" | jq -r '.kernel.file, (.initrd.file // empty), .disks[].file'); do
        cp "$src/$f" "$out/$f"
    done
    archs=$(echo "$archs" | jq -c --arg a "$arch" --argjson e "$entry" '.[$a] = $e')
done
[ "$archs" != '{}' ] || { echo "no disks of build.sh in $in" >&2; exit 1; }
min_ztcl=$(jq -r .min_ztcl "$src/manifest.json")
jq -n -c --arg n "$name" --arg v "$version" --argjson c "$counter" --arg m "$min_ztcl" --argjson a "$archs" \
    '{format: 1, name: $n, version: $v, counter: $c, min_ztcl: $m, archs: $a}' > "$out/manifest.json"
rm -f "$out/manifest.json.sig"
# ssh-keygen signs only with a private key of mode 0600, and a checkout gives
# the test key mode 0644.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat "$key" > "$tmp"
ssh-keygen -q -Y sign -f "$tmp" -n ztcl-vm-image "$out/manifest.json"
echo "manifest: $name $version, counter $counter"
