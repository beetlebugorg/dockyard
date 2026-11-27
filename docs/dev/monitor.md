# The sandbox monitor and the sharing panel (issue 15)

Date: 2026-11-27. State: first form. The monitor shows what the programs of the sandbox guest do: the calls of the egress proxy (allowed and blocked), the programs that start and end in the guest, the changes of the project folder, and the shares.

## The log

The monitor shows the audit log of the project: `audit.md` has its schema, its folder, and its commands. The dockyard window writes the records with `src/audit.tcl`. The monitor reads the last 10,000 records at its start, then the new records every 250 ms (`dockyard::audit query -after SEQ`).

The rules file (`dockyard-HASH.rules`) is next to the control socket of the project (`$XDG_RUNTIME_DIR`, or `/tmp` with the user ID), with mode 0600. `dockyard::monitor rule` and `dockyard::monitor rules` (`src/monitor.zig`) write and read it.

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
- The hooks of the agent program go to the log as `turn`, `tool`, and `note` records. The OpenTelemetry metrics of the agent program, the diff of each step, and the session replay of issue 15 are not started.
