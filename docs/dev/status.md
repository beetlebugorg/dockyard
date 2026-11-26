# Status

This page has the state of each step of the build order (section 9 of `spec.md`). Update it with each PR.

| Step | Repository | State |
|---|---|---|
| libghostty check | dockyard | Done: `libghostty.md`. Plan B: a VT parser in Zig in ztk. |
| PTY | ztcl | Linux merged: ztcl PRs 115 (plan) and 117 (`ztcl::pty`). macOS and Windows (ConPTY) are designed in ztcl `docs/dev/pty.md` and give an error. |
| `ztk::terminal` | ztk | Merged: ztk PR 80 (ztcl update) and PR 81 (the widget). |
| App window with the terminal pane | dockyard | Done: `src/main.zig`, `src/host.zig`, `src/dockyard.tcl`. The pane runs `claude` or the shell, and Return starts it again after it ends. |
| File watcher | ztcl | ztcl PR 120 (plan) and PR 121 (`ztcl::watch` on Linux). |
| Live preview | ztk, dockyard | Next. A first form runs the project in a child `ztk` process and starts it again on each change. The pane form needs ztk embedding (spec section 8, ztk item 5). |
| MCP bridge | ztcl, ztk, dockyard | Not started. |
| Build button | dockyard | Not started. |
| App list and history | dockyard | Not started. |
