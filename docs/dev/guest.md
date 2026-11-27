# The helper of the sandbox guest

`dockyard-guest` (`src/guest/main.zig`) is the helper of dockyard in the guest of `ztcl::vm` (issue 13). It gives the terminal pane a PTY in the guest, the guest programs a proxy port, and the monitor (issue 15) the programs that run. It uses no libc. `zig build` installs it for each guest architecture in `zig-out/lib/dockyard/guest/ARCH/dockyard-guest`. It is 22,304 bytes on x86-64 (`zig build-exe -target x86_64-linux-musl -OReleaseSmall -fstrip -fsingle-threaded`, `ls -l`, 2026-11-27). The hooks have a small JSON reader of their own (`Json` in `main.zig`): with `std.json` the same build was 65,728 bytes.

## The start

`sandbox.tcl` (`dockyard::sandbox::boot`) starts the guest and then the helper:

1. `ztcl::vm create` and `start`, with the project folder as the share `share0`. The agent of ztcl mounts `share0` at `/mnt/share`, and a bind mount puts it at `/work`. A second mount of the same 9p tag fails with EBUSY.
2. `ztcl::vm exec -binary 1` of `/bin/busybox sh -c {cat > /tmp/dockyard-guest ...}` copies the helper into the tmpfs of the guest.
3. `ztcl::vm exec` of `/tmp/dockyard-guest serve --relay PORT`. The helper mounts devpts at `/dev/pts` when the guest has none, opens its ports, goes to the background, and the `exec` ends.

On an x86-64 Linux with KVM, steps 1 to 3 take about 45 ms.

With `-image NAME`, the guest is a signed release of the store (`os/tools/manifest.sh`), and its second disk is the Claude Code disk (a third disk, the build disk with Zig, mounts at `/opt/zig`). The helper comes from that disk:

1. `ztcl::vm create -image NAME` and `start`, with the share as above.
2. One `ztcl::vm exec` of a shell script (`tools_mount` in `sandbox.tcl`). It mounts the squashfs of `/dev/dm-1` read-only at `/tmp/tools`, then `proc`, a recursive bind of `/dev`, a tmpfs at `tmp`, `root`, and `inbox`, and the share at its folder of the disk (`/work`). Then it runs `chroot /tmp/tools /usr/libexec/dockyard/dockyard-guest serve --relay PORT`.

The pane and its programs run in the chroot, so they find node, git, and Zig at the usual paths. `dockyard::sandbox::path VM PATH` gives the path in the guest of a path of the pane, for an `exec` outside the chroot. The hook command of the settings is the helper of the disk.

`dockyard --sandbox DIR` boots a release when `DIR` has a `manifest.json`. The app copies the manifest, its signature, and the files of its architecture to `.dockyard/guest/` of the project (`src/guest_release.zig`), and skips the copy when the manifest there is the same. It installs the release with `ztcl::vm image install` when the current counter of the store is another one. A Debug build trusts the test key of dockyard (`test_only`, a name that ends in `-test`). A release build trusts no key of dockyard yet.

## The ports

| vsock port | Use |
|---|---|
| 7100 | A terminal session: a program on a PTY. |
| 7101 | The relay, on the host: the helper connects once for each TCP client of the proxy port. |
| 7103 | The events: one JSON line for each program that starts or ends, and for each hook call of the agent program. |

The host connects to ports 7100 and 7103 of the guest. The helper connects to the relay port of the host (CID 2), where `ztcl::vm listen` accepts the connection.

## A session (port 7100)

Each message is a frame, as in the agent of ztcl (`docs/dev/vm-agent.md` of ztcl): `len u32 | type u8 | payload`, little endian, where `len` counts the type byte and the payload. A string is a `u32` length and the bytes. A list is a `u32` count and the strings.

| Type | Value | From | Payload |
|---|---|---|---|
| `open` | 0x01 | host | `rows u16`, `cols u16`, the `argv` list, the `env` list, the `cwd` string |
| `input` | 0x02 | host | bytes for the PTY |
| `resize` | 0x03 | host | `rows u16`, `cols u16` |
| `signal` | 0x04 | host | `signal u8`, for the process group of the program |
| `started` | 0x10 | guest | `pid u32` |
| `output` | 0x11 | guest | bytes of the PTY |
| `exit` | 0x12 | guest | `code i32`: the exit code, or minus the signal |
| `error` | 0x3f | guest | `errno u32`, `message` string |

The first frame is `open`. The program starts in a new session with the PTY as its terminal. `argv[0]` is a path: there is no search of `PATH`. A failed start gives `error` and no `started`. The connection ends after `exit`. A host that closes the connection ends the program with `SIGKILL`.

## The proxy port (port 7101 of the host)

The helper listens on `127.0.0.1:3128` of the guest. The kernel starts with the loopback device down, so the helper first sets the flag `IFF_UP` of `lo` (the ioctls `SIOCGIFFLAGS` and `SIOCSIFFLAGS` on a socket of `AF_INET`). The guest programs get `HTTPS_PROXY=http://127.0.0.1:3128`.

1. `dockyard::sandbox::boot` listens on a relay port of the host with `ztcl::vm listen`, before the helper starts, and gives the port to the helper (`serve --relay PORT`). On KVM the vsock ports of the host are one space for the whole host, so the port is the first free one from 7101.
2. For each new TCP client of port 3128, a child of the helper connects to the relay port of the host and copies the bytes between the client and that connection.
3. After `dockyard::sandbox::relay VM`, the host gives each connection to the egress proxy (`dockyard::proxy attach`), which reads the `CONNECT` request and checks the allow list. Before it, the host closes the connection.

With no listener on the host, the helper closes the client. A guest kernel with no IPv4 has no port 3128, and the helper writes `no IPv4 in this guest` on stderr.

## The events (port 7103)

Each line is a JSON object:

```json
{"type":"exec","time":1795766644261,"pid":36,"ppid":35,"argv":["/bin/busybox","sh","-l"]}
{"type":"exit","time":1795766644567,"pid":36}
```

`time` is the clock of the guest in ms since 1970. The helper reads `/proc` every 50 ms, so a program that runs for less than 50 ms can be missing. A program counts when the helper is one of its parents: the agent of ztcl and the helper are not in the stream. `dockyard::sandbox::events` gives each line to a script as a dict.

## The hooks of the agent program

`dockyard::sandbox::hooks VM HOME` writes `HOME/.claude/settings.json` in the guest, with the command `/tmp/dockyard-guest hook` for the events `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`, and `SubagentStop`. HOME is `/root`, outside `/work`, so the settings of the project stay as they are.

`dockyard-guest hook ?DIR?` reads the JSON of the hook on stdin (up to 256 KiB) and writes one flat line to a new file in DIR (default `/tmp/dockyard-hooks`), with a temporary name and a rename. It always exits with 0, so a hook does not block the agent program. The events stream reads the folder every 50 ms, sends each line, and removes the file:

```json
{"type":"hook","time":1795766645012,"event":"PostToolUse","tool":"Edit","session":"s1","path":"/work/main.tcl"}
```

The fields: `event` (`hook_event_name`), `tool` (`tool_name`), `session` (`session_id`), `prompt`, and from `tool_input` the fields `path` (`file_path`), `command`, `pattern`, and `url`. Each string is cut to 500 bytes at a UTF-8 boundary. A field that is not in the input is not in the line. `serve --hooks DIR` sets the folder of the stream.

## Tests

The tests run the helper on the host with `--unix DIR` (Unix sockets `DIR/7100` to `DIR/7103` in place of vsock), `--tcp PORT` for the proxy port, and `--foreground` (it writes `dockyard-guest: ready` on stderr). The guest test boots a guest when `DOCKYARD_GUEST_DIR` has the kernel (`bzImage` for x86-64, `Image` for arm64) and `agent.cpio`: on x86-64 Linux when the user can open `/dev/kvm`, and on macOS. On macOS the test program needs the entitlement `com.apple.security.virtualization`: run `zig build test-bin`, sign `zig-out/bin/test` with the entitlements file of ztcl (`tools/vm-guest/vz.entitlements`), and run it.
