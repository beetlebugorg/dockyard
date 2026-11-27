# Plan: the terminal pane in a microVM (issue 13) and the sandbox monitor (issue 15)

Date: 2026-11-26. State: plan. This page has the steps of issues 13 and 15. Each step is one PR.

## Rules

- dockyard is a ztk app. The UI is in Tcl. A Zig core gives each platform API as Tcl commands.
- Native APIs only: Virtualization.framework on macOS (through `ztcl::vm`), KVM on Linux, and the Host Compute Service on Windows. No libkrun, QEMU, Firecracker, or lwIP.
- The guest kernel and BusyBox are configured and built as binaries only. Nobody reads their source.
- The tests never run the agent program. They use `/bin/sh` or a fake program.

## The parts

| Part | Where | State |
|---|---|---|
| `ztcl::vm` on macOS (create, start, vsock, console, share) | ztcl | Merged (ztcl `docs/dev/vm.md`, steps 1 and 2). |
| The entitlement in the Zig signer | ztcl | ztcl `docs/dev/vm.md` step 3. |
| The guest agent (`exec`, `mount`, and a PTY over vsock) | ztcl | ztcl `docs/dev/vm.md` step 4. The terminal pane needs a PTY in the guest, so the agent needs an `op` for a PTY session: a vsock connection with the bytes of the PTY, and a resize frame. |
| The base image: the kernel and BusyBox | dockyard `os/` | Not started. |
| The disks of the pane: node and git, and Zig | dockyard `os/tools` | The disk, the manifest, and the test signature in CI (`.github/workflows/guest.yml`). The mount in the guest and the trust of the key in the app wait for ztcl PRs 435 and 455. |
| The egress proxy with an allow list | dockyard `src/sandbox/proxy.zig` | Step 1 below. |
| The terminal pane in the VM | dockyard | Step 4 below. First form on Linux KVM: the helper of the guest (`docs/dev/guest.md`) gives the PTY, the proxy port, and the events, so the agent of ztcl needs no PTY op. |
| KVM and HCS in `ztcl::vm` | ztcl | Not started. Linux and Windows wait for them. |

## The image (like Printdeck OS)

- A Buildroot external tree in `os/`, with a pinned Buildroot release, a defconfig for x86_64 and for aarch64, musl, and no package manager.
- The kernel: `tinyconfig` and a fragment with virtio PCI, virtio-console, virtio-blk, virtio-vsock, virtio-fs and FUSE, devtmpfs, EROFS for the read-only root, overlayfs, Unix and IPv4 sockets, PTYs, epoll, eventfd, and futex. No modules, no network device (the proxy goes over vsock), and no debug information.
- The base image is the kernel and a BusyBox root with the guest agent of ztcl as init. The disks of the pane are read-only squashfs disks after it.
- CI builds the images in a container and attaches them to a release with a manifest (versions, sizes, SHA-256) and a signature. dockyard has the public key, downloads the images on the first use, and refuses an image with a bad hash or signature.

## The network

The guest has no network device. A guest program reaches the network only through the egress proxy of the host:

1. The agent of the guest listens on `127.0.0.1:3128` in the guest and sends each connection over vsock to the host.
2. The host proxy reads `CONNECT host:port` (and plain `http://` requests), checks the host against the allow list, and connects or answers 403.
3. Each connection and each blocked attempt is an event: the time, the host, the port, the result, the bytes in each direction, and the duration. The monitor (issue 15) reads these events.

The default allow list is the API host of the agent program and the package registries that the user allows. The guest gets `HTTPS_PROXY=http://127.0.0.1:3128`.

## The threat model

A guest program can reach: the project folder (virtio-fs, read-write), the files that the user shares (read-only), the hosts of the allow list through the proxy, and the MCP bridge of dockyard over vsock. It cannot reach: other host files, the host network, the keychain, SSH keys, or the home folder. The login token of the agent program stays on the disk of the guest.

## Steps

1. The egress proxy in Zig (`src/sandbox/proxy.zig`), as Tcl commands `dockyard::proxy start|stop|allow|events`, with tests on Linux (a local server, an allowed connection, and a blocked attempt). It works with a host program today through `HTTPS_PROXY`, before the VM exists.
2. `os/`: the Buildroot tree, the kernel fragment, and a CI job that builds the base image for aarch64 and x86_64. Measure the size and the boot time on a Mac.
3. The tools disk and the release workflow with the manifest and the signature. The download and the update panel in the app.
4. `dockyard::vm` (Zig): the machine of a project with `ztcl::vm`, the project share, the proxy relay, and a PTY session for `ztk::terminal`. The terminal pane gets a mode `--sandbox vm` on macOS. A Mac session checks it.
5. The monitor core (issue 15): one event stream from the proxy, the agent (commands and file access), the hooks of the agent program, and its OpenTelemetry metrics, as one Tcl data model.
6. The monitor front ends in one program: the ztk window (a timeline, filters, the blocked tray, rules) and a TUI on `ztcl::vt`, picked by `--tui`, `--gui`, or the context.
7. The sharing panel: drop a file to share it read-only into `/inbox` of the guest, revoke it, and export a file out. Each share is an event of the timeline.
8. Linux (KVM) and Windows (HCS), when `ztcl::vm` has them.

## Questions

1. One VM for each project, or one VM for all the projects? Default: one for each project, so a project sees only its own folder.
2. The proxy sees only the host names of HTTPS connections (CONNECT). The bodies of the requests need a local CA that the guest trusts. Default: off, as issue 15 says.

## The disks of the pane

The guest of ztcl has BusyBox and the agent of ztcl only. The pane needs node and npm for the agent program, git, the helper of dockyard, and Zig for the builds of apps. These are on two read-only disks, in the image format of ztcl `docs/dev/vm-image.md` (user decision, 2026-11-27: keep the Claude Code disk small):

- The Claude Code disk (`ARCH-claude.img`): an Alpine root made by `apk` in a container of `alpine:3.24`, pinned by digest, with the packages `busybox`, `musl`, `ca-certificates`, `nodejs`, `npm`, and `git`, and the helper in `/usr/libexec/dockyard/`. The agent program is not on the disk: npm installs it in the guest, as a user installs it.
- The build disk (`ARCH-build.img`): Zig 0.17.0 from its release archive (checked by SHA-256). The pane mounts it at `/opt/zig` when the release has it, and `/usr/bin/zig` of the Claude Code disk links to `/opt/zig/zig`.
- `os/tools/build.sh ARCH` makes both disks: `mksquashfs` with xz and the branch filter of the architecture, blocks of 1 MiB, fixed times and owners, padded to 4 KiB blocks, then the `dm-verity` tree after the data with a fixed salt. `ARCH-packages.txt` lists the versions of the packages. The build is reproducible: two builds give the same bytes, and CI builds the disks twice and compares them with `cmp`. The log of apk (`/var/log/apk.log`) has the time of the build, so `rootfs.sh` removes it. The install script of `git-lfs` wrote the lines of `/etc/gitconfig` in a different order in each build, so the disk has no `git-lfs`. The disks are the same only for the same versions of the Alpine packages in `ARCH-packages.txt`.
- The Claude Code disk is a whole root, so the programs find their libraries at the usual paths. `dockyard::sandbox::boot -image` mounts it at `/tmp/tools` of the guest and runs the helper and the pane in a chroot of it (`docs/dev/guest.md`).
- The compression: xz by default. The guest kernel of ztcl has `CONFIG_SQUASHFS_XZ` since ztcl-guest-kernel run 46020516028 (ztcl issue 484). xz made the disk of node, git, and Zig about 27% smaller than gzip (77,545,472 bytes against 105,672,704). `COMP=gzip` is for an older kernel.
- The releases (`os/tools/manifest.sh`): the kernel and the root disk of a ztcl guest release, then the disks of `DISKS`. `dockyard-guest-test` has the Claude Code disk as `disks[1]` (`/dev/vdb`, the dm-verity device `/dev/dm-1`). `dockyard-guest-build-test` also has the build disk as `disks[2]` (`/dev/vdc`, `/dev/dm-2`). The command line waits for each disk and has one `dm-mod.create` device for each. A ztcl release attaches each disk of its manifest, so the build disk is in a release of its own (questions.md). The counter is the commit time of HEAD.
- The signature: the test key of dockyard (`os/tools/testkey`, `SHA256:gchh612FPBuG9Y27nSPqS/MTagl9PCQs6PovKhs8Q94`) signs the names that end in `-test`, in the namespace `ztcl-vm-image`. Its private half is in the repository, so the app trusts it only as a `test_only` key (ztcl PR 455, `Interp.vm_host.image_keys`) and only in a Debug build. A release key of dockyard and its environment come later, with the owner of the repository.
- The CI job (`.github/workflows/guest.yml`): the two disks on an x86-64 runner and an arm64 runner, then the two manifests and the check of their signatures with `ssh-keygen -Y verify`, as the artifacts `dockyard-guest-test` and `dockyard-guest-build-test`.
- The sizes (x86-64, xz, `stat` in `build.sh`, 2026-11-27):

  | Part | Bytes |
  |---|---|
  | The Claude Code disk | 26,038,272 |
  | The build disk | 52,092,928 |
  | The disk of node, git, and Zig before the split | 78,139,392 |
  | The agent program as npm installs it (`@anthropic-ai/claude-code` 2.1.332 on an x86-64 host, measured with `du -sb`) | 402,536,197 |

  npm installs one native binary package for the platform (402,326,322 bytes of the total), and the postinstall script runs `node install.cjs`. The place of this install in the guest is open (questions.md): a tmpfs install downloads it at each boot.
- The times (x86-64 KVM, 256 MB, the KVM release test, two runs of each release, on a host with a load of about 20 on 8 cores, 2026-11-27): the uptime of the guest at the first command of the pane is 0.19 to 0.32 s with the Claude Code disk, and 0.21 to 0.60 s with both disks. The whole test (the install of the release with its SHA-256 checks, the boot, the commands, and the delete) is 8.7 to 9.7 s with the Claude Code disk, and 21.5 to 41.5 s with both disks. The first `zig version` and the larger install are the difference.
- Zig on the build disk has the libc headers and sources for Linux and WASI only. The pane builds and tests for Linux, and the Build of the app makes the other platforms on the host. `zig build-exe` for `x86_64-linux-musl` and `aarch64-linux-gnu` works in a chroot of the disk, and `x86_64-windows` gives `DllImportLibraryNotFound`. git has `git-remote-http` and no programs for other transports or for servers. The disks have no `openssh-client`, no `doc` folder of Zig, and no man pages.
- `dockyard --sandbox DIR` with the release of `manifest.sh` in `DIR` installs the release and boots it with `create -image` (`src/sandbox/guest_release.zig`). The KVM test `the pane runs from the disks of a signed release` runs node and git in the chroot, and Zig with the build disk, with `DOCKYARD_GUEST_RELEASE` set to a release folder. It prints the uptime of the guest at the first command and the time of the whole test.
- node in the guest: node runs with its JIT. The JIT of V8 needs `madvise`, and the guest kernel has `CONFIG_ADVISE_SYSCALLS` since ztcl-guest-kernel run 46020516028. With an older kernel, node stops with `Check failed: 0 == ret`.
- Next: the update panel of issue 13, and a release key of dockyard. The copy of the helper over `exec` stays for a guest without `-image`.
