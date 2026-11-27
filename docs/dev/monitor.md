# The sandbox monitor and the sharing panel (issue 15)

Date: 2026-11-27. State: first form. The monitor shows what the programs of the sandbox guest do: the calls of the egress proxy (allowed and blocked), the programs that start and end in the guest, the changes of the project folder, and the shares.

## The log

The dockyard window writes one line for each event with `dockyard::monitor log` (`src/monitor.zig`). A line is a Tcl dict with `kind`, `time` (ms since 1970), and the fields of the kind:

| `kind` | Fields | Source |
|---|---|---|
| `net` | `host`, `port`, `result` (`allowed`, `blocked`, `failed`, `refused`), `up`, `down`, `ms` | `dockyard::proxy events`, every 250 ms |
| `exec` | `pid`, `ppid`, `argv` | port 7103 of the guest helper (`docs/dev/guest.md`) |
| `exit` | `pid` | the same |
| `file` | `op`, `path` | the file watcher of the preview (`ztcl::watch`) |
| `share` | `op` (`share`, `revoke`, `export`), `name` | the sharing panel |
| `rule` | `rule` (`allow`, `block`), `host` | the rules of the monitor |

The log is a file next to the control socket of the project (`$XDG_RUNTIME_DIR/dockyard-HASH.monitor`, or in `/tmp` with the user ID), with mode 0600. It is outside the project folder, because the guest can write the project folder. The rules file (`dockyard-HASH.rules`) is next to it.

## The front ends

`dockyard --monitor PROJECT` opens the window of the monitor (`src/monitor.tcl`): a filter, a check button for each kind, the timeline with a color for each kind, and the tray of the blocked hosts. Allow on a blocked host writes an `allow` rule. The dockyard window reads the rules every 250 ms and gives the proxy its default allow list with the rules applied.

`dockyard --monitor --tui PROJECT` runs on the headless backend and writes each event as one line with an ANSI color to the terminal. It is the same program and the same script.

## The sharing panel

The Shares button of the dockyard window (in `--sandbox` mode) opens the panel:

- Share: a file of the project goes to `/inbox/NAME` in the guest, with mode 0444.
- Revoke: the file goes out of `/inbox`.
- Export: a file of the guest goes to `exports/` of the project.

Each step is a `share` event.

## Limits of this form

- The guest programs run as root, so mode 0444 in `/inbox` does not stop a write. A read-only share of the hypervisor needs a folder outside the project, and the paths of `ztcl::vm` must be below the root folder of `file` (the project). The question is in the queue of the ztcl maintainers.
- The file events are the changes of the watcher: writes, creates, and removes. The reads of the guest are not in the log. The 9p server of ztcl (ztcl PR 385) is the place to count them.
- A program of the guest that runs for less than 50 ms can be missing (the helper reads `/proc` every 50 ms).
- A file is shared from the project folder only. The drop of a file from outside the project needs a path outside the file jail.
- The hooks and the OpenTelemetry metrics of the agent program, the diff of each step, and the session replay of issue 15 are not started.
