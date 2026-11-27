# The architecture of dockyard

This page is the map of the source tree. It says what each module owns, which module can call which, and where a new feature goes.

## The module map

| Folder | Owns | Files |
|---|---|---|
| `src/` | The two roots of the Zig modules. Zig reads only files below the folder of a root, so the roots stay here. | `main.zig` (the flags, the commands of each mode, the script of each mode), `tests.zig` (the window tests, and the imports of the tests of the other modules) |
| `src/app/` | The core of the window: the project, the agent program, the preview child and its bridge, Build, the app list, and crash reports. | `crash.zig` (the crash reports), `host.zig` (the capabilities, the variables of the window, the control path), `control.zig` (the control socket of the preview child), `mcp.zig` (`dockyard --mcp`), `apps.zig` (Build and the app list), `dockyard.tcl` (the agent program, the preview, the files of the bridge), `bridge.tcl` (the script of the preview child), `project/` (the files that dockyard writes into a new project) |
| `src/ui/` | The look and the views of the window. | `theme.tcl` (the stylesheet, the icons, and the shared parts), `ui.tcl` (the header, Workspace, Apps, the status bar, the keys), `activity.tcl` (the Activity view), `icon.tcl` and `ui-icons.tcl` (image data made by `tools/icons.py` and `tools/ui-icons.py`) |
| `src/sandbox/` | The VM of the terminal pane, its network, and the monitor. | `sandbox.zig` and `sandbox.tcl` (the guest and its sessions), `guest_release.zig` (signed guest releases), `proxy.zig` (the egress proxy), `sock.zig` (sockets at a path), `monitor.zig` and `monitor.tcl` (`dockyard --monitor`), `guest_test.zig` (the test with a real guest) |
| `src/audit/` | The audit log: the records, the hash chain, the index, the export. | `audit.zig` (the log and `dockyard::audit`), `audit.tcl` (the records of the window) |
| `src/guest/` | The helper program in the guest. It is its own Zig module. | `main.zig` |

## The rules

1. The views talk to the rest of the window only through the `::dockyard` namespace: the commands of Zig (`dockyard::audit`, `dockyard::build::*`, `dockyard::apps::*`, `dockyard::monitor`, `dockyard::proxy`) and the procs of `app/dockyard.tcl`. A view does not read the files of another module.
2. `src/sandbox/` and `src/audit/` have no UI code. They give commands and records. The window shows them.
3. `src/app/` calls the views only through `::dockyard::ui::*` procs (the state of a pane, an item of the status bar). One exception is left: the sharing panel of the sandbox (`::dockyard::vm::shares` in `app/dockyard.tcl`) makes its own toplevel. It moves to `src/ui/` with the VMs panel.
4. The guest (`src/guest/`) shares no code with the host. The protocol (the ports, the JSON lines of the events) is in `docs/dev/guest.md`.
5. Each Zig file has the tests of its own module. `src/tests.zig` imports them and has the tests of the whole window.
6. A path of a file is relative to the file that imports or embeds it (`@import("../sandbox/sock.zig")`).

## Where a new feature goes

| Feature | Folder |
|---|---|
| A view, a panel, a dialog, a part of the look | `src/ui/` (and its parts in `theme.tcl`) |
| A command of the window for the views | `src/app/` (Zig in `apps.zig` or a new file, Tcl in `dockyard.tcl`) |
| A kind of audit record, or a reader of the log | `src/audit/` |
| A source of records in the guest or the network | `src/sandbox/`, with the record written through `dockyard::audit` |
| A tool of the MCP bridge | `src/app/mcp.zig` and `src/app/bridge.tcl` |
| The program in the guest | `src/guest/` |
