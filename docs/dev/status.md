# Status

This page has the state of each step of the build order (section 9 of `spec.md`). Update it with each PR.

| Step | Repository | State |
|---|---|---|
| libghostty check | dockyard | Done: `libghostty.md`. Plan B: a VT parser in Zig in ztk. |
| PTY | ztcl | Linux merged: ztcl PRs 115 (plan) and 117 (`ztcl::pty`). macOS and Windows (ConPTY) are designed in ztcl `docs/dev/pty.md` and give an error. |
| `ztk::terminal` | ztk | Merged: ztk PR 80 (ztcl update) and PR 81 (the widget). |
| App window with the terminal pane | dockyard | Done: `src/main.zig`, `src/host.zig`, `src/dockyard.tcl`. The pane runs `claude` or the shell, and Return starts it again after it ends. |
| File watcher | ztcl | Merged: ztcl PR 120 (plan) and PR 121 (`ztcl::watch` on Linux). |
| CI | dockyard | Done: `.github/workflows/ci.yml` (dockyard PR 3). Each change to main goes in a PR. |
| Live preview, first form | ztk, dockyard | Done: ztk PR 93 (ztcl with `ztcl::watch`). The preview pane runs `dockyard --run main.tcl` on a PTY, shows its output, and starts it again 150 ms after the last change outside `.git`. On Wayland the app opens its own window. |
| Live preview, pane form | ztk, dockyard | Next. It needs ztk embedding (spec section 8, ztk item 5), the sandbox of the project, and a reload with no restart. |
| MCP bridge | ztcl, ztk, dockyard | Not started. |
| Build button | dockyard | Not started. |
| App list and history | dockyard | Not started. |

## Next steps

1. The pane form of the preview: a ztk embedding of the window of a child interpreter in a pane, with the capabilities that the project declares and `ztk::limit`. Reload the changed files in the child with no restart where possible.
2. The MCP bridge (spec section 5): `ztk::snapshot`, a widget tree dump, event injection, and a small MCP server over stdio.
3. The Build button and the app list (spec sections 6 and 7).

## Notes

- The preview child has `file`, `channels` (for `source`), and `clock`, with the project folder as the root folder (`src/host.zig`).
- The tests run the installed `dockyard` program as the preview child (`DOCKYARD_EXE` in `build.zig`), in a new folder `/tmp/dockyard-test-*` for each test.
