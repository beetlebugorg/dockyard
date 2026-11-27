#!/bin/sh
# Runs in the Alpine container of build.sh, as root. Makes the root of
# the tools disk in /rootfs with apk, adds Zig from its release archive
# (checked by SHA-256) and the guest helper, then makes the squashfs and
# its dm-verity hash tree in /out. The inputs are in /in.
set -eu
arch=$1 zig_sha=$2 salt=$3
apk add -q squashfs-tools cryptsetup
mkdir -p /rootfs/etc/apk
cp -r /etc/apk/keys /rootfs/etc/apk/
cp /etc/apk/repositories /rootfs/etc/apk/
# The packages of the pane: a shell, node and npm for the agent program,
# git, and the certificates for HTTPS through the proxy.
apk add -q --root /rootfs --initdb --no-cache \
    alpine-baselayout busybox busybox-binsh musl ca-certificates \
    nodejs npm git git-lfs openssh-client
apk info --root /rootfs -v | sort > /out/packages.txt
echo "$zig_sha  /in/zig.tar.xz" | sha256sum -c -s
mkdir -p /rootfs/opt/zig
tar -xJf /in/zig.tar.xz -C /rootfs/opt/zig --strip-components=1
ln -sf /opt/zig/zig /rootfs/usr/bin/zig
mkdir -p /rootfs/usr/libexec/dockyard /rootfs/work /rootfs/inbox
install -m 755 /in/dockyard-guest /rootfs/usr/libexec/dockyard/dockyard-guest
rm -rf /rootfs/var/cache/apk/* /rootfs/lib/apk/db/scripts.tar*
rm -f /out/tools.img
mksquashfs /rootfs /out/tools.img -noappend -all-root -no-xattrs -comp xz \
    -mkfs-time 0 -all-time 0 -reproducible -quiet -no-progress
# The data fills whole blocks of 4,096 bytes, and the tree starts after it.
size=$(stat -c %s /out/tools.img)
blocks=$(( (size + 4095) / 4096 ))
truncate -s $(( blocks * 4096 )) /out/tools.img
veritysetup format /out/tools.img /out/tools.img --hash-offset=$(( blocks * 4096 )) \
    --no-superblock --salt="$salt" --data-block-size=4096 --hash-block-size=4096 \
    --hash=sha256 > /out/verity.txt
echo "$blocks" > /out/blocks.txt
