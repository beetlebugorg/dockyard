#!/bin/sh
# Runs in the Alpine container of build.sh, as root. Makes the root of
# the tools disk in /rootfs with apk, adds Zig from its release archive
# (checked by SHA-256) and the guest helper, then makes the squashfs and
# its dm-verity hash tree in /out. The inputs are in /in.
set -eu
arch=$1 zig_sha=$2 salt=$3 comp=${4:-gzip}
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
mkdir -p /rootfs/opt/zig
tar -xJf /in/zig.tar.xz -C /rootfs/opt/zig --strip-components=1
# The pane builds and tests for Linux only. The Build of the app makes the
# binaries for the other platforms on the host, so the headers and the
# libc sources of the other systems are not on the disk.
(cd /rootfs/opt/zig && rm -rf doc \
    lib/libc/include/*-windows* lib/libc/include/*-darwin* \
    lib/libc/include/*-freebsd* lib/libc/include/*-netbsd* lib/libc/include/*-openbsd* \
    lib/libc/mingw lib/libc/darwin lib/libc/freebsd lib/libc/netbsd lib/libc/openbsd)
ln -sf /opt/zig/zig /rootfs/usr/bin/zig
mkdir -p /rootfs/usr/libexec/dockyard /rootfs/work /rootfs/inbox
install -m 755 /in/dockyard-guest /rootfs/usr/libexec/dockyard/dockyard-guest
# The log of apk has the time of the build.
rm -rf /rootfs/var/cache/apk/* /rootfs/lib/apk/db/scripts.tar* /rootfs/var/log/apk.log \
    /rootfs/usr/share/man /rootfs/usr/share/doc
rm -f /out/tools.img
# The compression is gzip by default, since the guest kernel of ztcl has
# the zlib decompressor of squashfs only. comp=xz makes the disk about 27%
# smaller, with blocks of 1 MiB and the branch filter of the architecture,
# for a kernel with CONFIG_SQUASHFS_XZ.
case $comp in
    xz) case $arch in x86_64) opts="-comp xz -Xbcj x86" ;; arm64) opts="-comp xz -Xbcj arm64" ;; esac ;;
    gzip) opts="-comp gzip -Xcompression-level 9" ;;
    *) echo "comp must be gzip or xz" >&2; exit 2 ;;
esac
mksquashfs /rootfs /out/tools.img -noappend -all-root -no-xattrs -b 1M $opts \
    -mkfs-time 0 -all-time 0 -reproducible -quiet -no-progress
# The data fills whole blocks of 4,096 bytes, and the tree starts after it.
size=$(stat -c %s /out/tools.img)
blocks=$(( (size + 4095) / 4096 ))
truncate -s $(( blocks * 4096 )) /out/tools.img
veritysetup format /out/tools.img /out/tools.img --hash-offset=$(( blocks * 4096 )) \
    --no-superblock --salt="$salt" --data-block-size=4096 --hash-block-size=4096 \
    --hash=sha256 > /out/verity.txt
echo "$blocks" > /out/blocks.txt
