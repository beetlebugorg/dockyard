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
| Live preview, pane form: plan | ztk | ztk PR 95: `docs/dev/embed.md` (`ztk::embed`, an embed backend, a shared atlas, the copy of the child scene). |
| MCP bridge: ztk parts | ztk | ztk PR 96: `ztk::snapshot` (base64 PNG of a widget, drawn with the CPU renderer) and `ztk::tree` (the widgets with their geometry). Event injection is `event generate`; check pointer events end to end. dockyard uses ztk 4d53bc0. |
| MCP bridge: server | ztcl or dockyard | Not started. |
| Build button | dockyard | Not started. |
| App list and history | dockyard | Not started. |

## Next steps

1. The pane form of the preview: a ztk embedding of the window of a child interpreter in a pane, with the capabilities that the project declares and `ztk::limit`. Reload the changed files in the child with no restart where possible.
2. The MCP bridge (spec section 5): `ztk::snapshot`, a widget tree dump, event injection, and a small MCP server over stdio.
3. The Build button and the app list (spec sections 6 and 7).

## Notes

- The MCP server needs a control path into the preview interpreter. With the child process form, the child has no `socket` capability. One way: the Zig code of `dockyard --run` reads Tcl requests from a pipe or a loopback socket that the host opens before `main.tcl` runs, and evaluates them in the child interpreter from a timer of the loop. With `ztk::embed`, the parent evaluates them directly.
- Open bug: a run of `dockyard --headless --exit-after-frames 3` did not end on the GitHub runner (60 s limit) and ends in 0.2 s locally. The cause is not known. CI runs only the build and the tests. If the bug occurs with ztk alone, file it as a ztk issue.

- The preview child has `file`, `channels` (for `source`), and `clock`, with the project folder as the root folder (`src/host.zig`).
- The tests run the installed `dockyard` program as the preview child (`DOCKYARD_EXE` in `build.zig`), in a new folder `/tmp/dockyard-test-*` for each test.
