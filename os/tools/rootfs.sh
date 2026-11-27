#!/bin/sh
# Runs in the Alpine container of build.sh, as root. Makes the two disks
# of the sandbox guest in /out, each a squashfs with its dm-verity hash
# tree after the data:
#   claude.img  the root of the pane: the programs of the agent program
#               (a shell, node, npm, git, the certificates) and the guest
#               helper. The agent program itself is not on the disk: npm
#               installs it in the guest, as a user installs it.
#   build.img   Zig, from its release archive (checked by SHA-256). The
#               pane mounts it at /opt/zig when dockyard builds apps.
# The inputs are in /in.
set -eu
arch=$1 zig_sha=$2 salt=$3 comp=${4:-xz}
apk add -q squashfs-tools cryptsetup
mkdir -p /rootfs/etc/apk
cp -r /etc/apk/keys /rootfs/etc/apk/
cp /etc/apk/repositories /rootfs/etc/apk/
# The packages of the pane: a shell, node and npm for the agent program,
# git, and the certificates for HTTPS through the proxy. git-lfs is not
# here: its install script writes the lines of /etc/gitconfig in a
# different order in each build. openssh-client is not here: the guest
# reaches the network only through the HTTP proxy, so git uses HTTPS.
apk add -q --root /rootfs --initdb --no-cache \
    alpine-baselayout busybox busybox-binsh musl ca-certificates \
    nodejs npm git
# git over HTTPS needs git-remote-http only. These programs are for other
# transports and for servers.
for f in git-http-fetch git-http-push git-imap-send git-daemon git-shell \
    git-http-backend git-sh-i18n--envsubst; do
    rm -f /rootfs/usr/libexec/git-core/$f /rootfs/usr/bin/$f
done
apk info --root /rootfs -v | sort > /out/packages.txt
echo "$zig_sha  /in/zig.tar.xz" | sha256sum -c -s
mkdir -p /zigroot /rootfs/opt/zig
tar -xJf /in/zig.tar.xz -C /zigroot --strip-components=1
# The pane builds and tests for Linux only. The Build of the app makes the
# binaries for the other platforms on the host, so the headers and the
# libc sources of the other systems are not on the disk.
(cd /zigroot && rm -rf doc \
    lib/libc/include/*-windows* lib/libc/include/*-darwin* \
    lib/libc/include/*-freebsd* lib/libc/include/*-netbsd* lib/libc/include/*-openbsd* \
    lib/libc/mingw lib/libc/darwin lib/libc/freebsd lib/libc/netbsd lib/libc/openbsd)
# /opt/zig is the mount point of the build disk. Without the build disk
# the link has no target.
ln -sf /opt/zig/zig /rootfs/usr/bin/zig
mkdir -p /rootfs/usr/libexec/dockyard /rootfs/work /rootfs/inbox
install -m 755 /in/dockyard-guest /rootfs/usr/libexec/dockyard/dockyard-guest
# The log of apk has the time of the build.
rm -rf /rootfs/var/cache/apk/* /rootfs/lib/apk/db/scripts.tar* /rootfs/var/log/apk.log \
    /rootfs/usr/share/man /rootfs/usr/share/doc
# The compression is xz by default, with blocks of 1 MiB and the branch
# filter of the architecture. The guest kernel of ztcl has
# CONFIG_SQUASHFS_XZ from ztcl-guest-kernel run 46020516028. comp=gzip is
# for an older kernel with the zlib decompressor only.
case $comp in
    xz) case $arch in x86_64) opts="-comp xz -Xbcj x86" ;; arm64) opts="-comp xz -Xbcj arm64" ;; esac ;;
    gzip) opts="-comp gzip -Xcompression-level 9" ;;
    *) echo "comp must be gzip or xz" >&2; exit 2 ;;
esac
# Makes /out/NAME.img from the folder ROOT, pads the data to whole
# blocks of 4,096 bytes, and puts the tree after it.
disk() {
    name=$1 root=$2
    rm -f "/out/$name.img"
    mksquashfs "$root" "/out/$name.img" -noappend -all-root -no-xattrs -b 1M $opts \
        -mkfs-time 0 -all-time 0 -reproducible -quiet -no-progress
    size=$(stat -c %s "/out/$name.img")
    blocks=$(( (size + 4095) / 4096 ))
    truncate -s $(( blocks * 4096 )) "/out/$name.img"
    veritysetup format "/out/$name.img" "/out/$name.img" --hash-offset=$(( blocks * 4096 )) \
        --no-superblock --salt="$salt" --data-block-size=4096 --hash-block-size=4096 \
        --hash=sha256 > "/out/$name-verity.txt"
    echo "$blocks" > "/out/$name-blocks.txt"
}
disk claude /rootfs
disk build /zigroot
