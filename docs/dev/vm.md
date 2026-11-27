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
| The tools disk: the agent program, git, and Zig | dockyard `os/` | Not started. |
| The egress proxy with an allow list | dockyard `src/proxy.zig` | Step 1 below. |
| The terminal pane in the VM | dockyard | Step 4 below. First form on Linux KVM: the helper of the guest (`docs/dev/guest.md`) gives the PTY, the proxy port, and the events, so the agent of ztcl needs no PTY op. |
| KVM and HCS in `ztcl::vm` | ztcl | Not started. Linux and Windows wait for them. |

## The image (like Printdeck OS)

- A Buildroot external tree in `os/`, with a pinned Buildroot release, a defconfig for x86_64 and for aarch64, musl, and no package manager.
- The kernel: `tinyconfig` and a fragment with virtio PCI, virtio-console, virtio-blk, virtio-vsock, virtio-fs and FUSE, devtmpfs, EROFS for the read-only root, overlayfs, Unix and IPv4 sockets, PTYs, epoll, eventfd, and futex. No modules, no network device (the proxy goes over vsock), and no debug information.
- The base image is the kernel and a BusyBox root with the guest agent of ztcl as init. The tools disk is a second read-only EROFS disk.
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

1. The egress proxy in Zig (`src/proxy.zig`), as Tcl commands `dockyard::proxy start|stop|allow|events`, with tests on Linux (a local server, an allowed connection, and a blocked attempt). It works with a host program today through `HTTPS_PROXY`, before the VM exists.
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
