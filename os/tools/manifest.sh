#!/bin/sh
# Writes the signed release of the dockyard guest in out/: the kernel and
# the root disk of a ztcl guest release (ZTCL_IMAGE, a folder with its
# manifest.json and files), and the tools disk of build.sh as the second
# disk of each architecture. The command line maps the tools disk
# (/dev/vdb) as the second dm-verity device, /dev/dm-1.
#   sh manifest.sh                     signs with the test key, name dockyard-guest-test
# The private half of the test key is in the repository: anyone can sign
# with it, so it signs only a name that ends in -test.
#   KEY=path NAME=dockyard-guest sh manifest.sh   signs with a release key
# The counter is the commit time of HEAD, so it grows on main.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${OUT:-$here/out}
src=${ZTCL_IMAGE:?ZTCL_IMAGE is the folder of a ztcl guest release}
key=${KEY:-$here/testkey/test_ed25519}
name=${NAME:-dockyard-guest-test}
version=${VERSION:-0.1.0}
counter=${COUNTER:-$(git -C "$here" log -1 --format=%ct)}
archs='{}'
for arch in x86_64 arm64; do
    [ -f "$out/$arch-tools.json" ] || continue
    base=$(jq -c --arg a "$arch" '.archs[$a] // empty' "$src/manifest.json")
    [ -n "$base" ] || { echo "$arch: not in $src/manifest.json" >&2; exit 1; }
    tools=$(cat "$out/$arch-tools.json")
    blocks=$(( $(echo "$tools" | jq .verity.hash_offset) / 4096 ))
    hash=$(echo "$tools" | jq -r .verity.root_hash)
    salt=$(echo "$tools" | jq -r .verity.salt)
    table="0 $(( blocks * 8 )) verity 1 /dev/vdb /dev/vdb 4096 4096 $blocks $blocks sha256 $hash $salt"
    cmdline=$(echo "$base" | jq -r .cmdline)
    case $cmdline in *'dm-mod.waitfor=/dev/vda '*'dm-mod.create="'*'"'*) ;;
        *) echo "$arch: the command line has no dm-verity root" >&2; exit 1 ;; esac
    # The second device goes after the first in dm-mod.create, with ";".
    cmdline=$(printf '%s' "$cmdline" | sed "s|dm-mod.waitfor=/dev/vda |dm-mod.waitfor=/dev/vda,/dev/vdb |; s|\\(dm-mod.create=\"[^\"]*\\)\"|\\1;tools,,,ro,$table\"|")
    entry=$(echo "$base" | jq -c --arg c "$cmdline" --argjson t "$tools" '.cmdline = $c | .disks += [$t]')
    for f in $(echo "$base" | jq -r '.kernel.file, (.initrd.file // empty), .disks[].file'); do
        cp "$src/$f" "$out/$f"
    done
    archs=$(echo "$archs" | jq -c --arg a "$arch" --argjson e "$entry" '.[$a] = $e')
done
[ "$archs" != '{}' ] || { echo "no tools disk in $out" >&2; exit 1; }
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
