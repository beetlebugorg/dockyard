# The helper of the sandbox guest

`dockyard-guest` (`src/guest/main.zig`) is the helper of dockyard in the guest of `ztcl::vm` (issue 13). It gives the terminal pane a PTY in the guest, the guest programs a proxy port, and the monitor (issue 15) the programs that run. It uses no libc. `zig build` installs it for each guest architecture in `zig-out/lib/dockyard/guest/ARCH/dockyard-guest`. It is 65,544 bytes on x86-64 (`ls -l`, 2026-11-27). The JSON parser of the hooks (`std.json`) is most of it: the helper was 16,792 bytes before.

## The start

`sandbox.tcl` (`dockyard::sandbox::boot`) starts the guest and then the helper:

1. `ztcl::vm create` and `start`, with the project folder as the share `share0`. The agent of ztcl mounts `share0` at `/mnt/share`, and a bind mount puts it at `/work`. A second mount of the same 9p tag fails with EBUSY.
2. `ztcl::vm exec` of `/bin/busybox sh -c {base64 -d > /tmp/dockyard-guest ...}` copies the helper into the tmpfs of the guest. The input of `exec` goes as UTF-8 text, so the bytes go as base64. The tools disk of `vm.md` will have the helper, and this step goes away.
3. `ztcl::vm exec` of `/tmp/dockyard-guest serve`. The helper mounts devpts at `/dev/pts` when the guest has none, opens its ports, goes to the background, and the `exec` ends.

On an x86-64 Linux with KVM, steps 1 to 3 take about 45 ms.

## The ports

| vsock port | Use |
|---|---|
| 7100 | A terminal session: a program on a PTY. |
| 7101 | The relay control: one id for each TCP client of the proxy port. |
| 7102 | The relay data: the host sends an id, then the bytes go both ways. |
| 7103 | The events: one JSON line for each program that starts or ends, and for each hook call of the agent program. |

The host connects to each port. The guest connects to nothing on the host, so the same helper works with each backend of `ztcl::vm`.

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

## The proxy port (ports 7101 and 7102)

The helper listens on `127.0.0.1:3128` of the guest. The kernel starts with the loopback device down, so the helper first sets the flag `IFF_UP` of `lo` (the ioctls `SIOCGIFFLAGS` and `SIOCSIFFLAGS` on a socket of `AF_INET`). The guest programs get `HTTPS_PROXY=http://127.0.0.1:3128`.

1. The host keeps one connection on port 7101. For each new TCP client of port 3128, the helper sends the id of the client as `u32`. It sends the ids of waiting clients again after a new control connection.
2. For each id, the host opens a connection on port 7102 and sends the id as `u32`.
3. The helper copies the bytes between the client and that connection. The host gives the connection to the egress proxy (`dockyard::proxy attach`), which reads the `CONNECT` request and checks the allow list.

A client with no data connection after 10 seconds is closed. A guest kernel with no IPv4 has no port 3128, and the helper writes `no IPv4 in this guest` on stderr.

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
