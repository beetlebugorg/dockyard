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
| Live preview, first form | ztk, dockyard | Done: ztk PR 93 (ztcl with `ztcl::watch`). The preview pane runs `dockyard --run main.tcl` on a PTY, shows its output, and starts it again 150 ms after the last change outside `.git`. |
| Live preview, pane form (image) | dockyard | Done (dockyard PR 7). The child runs on the headless backend. Every 33 ms the window asks the child for its count of frames over the control socket, and reads `ztk::snapshot .` when the count changes. The child gets the size of the pane with `wm geometry`. The input of the pane goes to the child with `ztk::inject`. This form works on each platform with a headless backend. |
| Live preview, pane form (`ztk::embed`) | ztk, dockyard | Not started. The in-process form of ztk `docs/dev/embed.md`, for a reload with no restart and a draw with no image copy. |
| Live preview, pane form: plan | ztk | ztk PR 95: `docs/dev/embed.md` (`ztk::embed`, an embed backend, a shared atlas, the copy of the child scene). |
| MCP bridge: ztk parts | ztk | ztk PR 96: `ztk::snapshot` (base64 PNG of a widget, drawn with the CPU renderer) and `ztk::tree` (the widgets with their geometry). Event injection is `event generate`; check pointer events end to end. dockyard uses ztk 4d53bc0. |
| MCP bridge: events | ztk | ztk PR 97: `ztk::inject`. `event generate` leaves the hover flag of the dispatcher clear, so a generated press and release did not invoke a button. `ztk::inject` gives backend events to `App.handleEvent`. dockyard uses ztk 4695cb7. |
| MCP bridge: server | dockyard | Done (dockyard PR 6): `src/mcp.zig` (`dockyard --mcp`, JSON-RPC over stdio), `src/control.zig` (the control socket of the preview child), `src/bridge.tcl` (the tools in Tcl), `src/project/CLAUDE.md` (the template), and `.mcp.json`. |
| Build button | dockyard | Not started. |
| App list and history | dockyard | Not started. |

## Next steps

1. The Build button and the app list (spec sections 6 and 7).
2. `ztk::embed` from ztk `docs/dev/embed.md`. PR 1 of that plan shares the fonts and the atlas of the parent App. `App.fonts` and `App.atlas` are values, with 40 uses in 13 files, and 3 of the files (`appkit.zig`, `windows.zig`, `d3d12.zig`) are in the macOS and Windows work (`grep -rn "app\.atlas\b\|\.atlas\.\|app\.fonts\b\|\.fonts\." src`). Agree on the change with the owners of those files first.

## Notes

- The bridge: the agent program starts `dockyard --mcp` from `.mcp.json` in the project folder. That process connects to a Unix socket of the preview child at `$XDG_RUNTIME_DIR/dockyard-<hash of the project path>.sock` (or `/tmp/dockyard-<uid>-<hash>.sock`). The Zig code of the child opens the socket before main.tcl runs, and a native timer of the loop polls it every 20 ms. The Tcl script of the child still has no `socket` command. With `ztk::embed`, the parent can evaluate the requests directly.
- The `restart` tool ends the child with status 75, and the window script starts a new run.
- After an error in main.tcl, the child keeps running, so the `errors` tool can give the trace.
- dockyard writes `.mcp.json` and `CLAUDE.md` into a project that has none. `.mcp.json` has the full path of the dockyard program. The agent program asks the user to approve a server of a project file before it uses it (not checked here: the tests never run the agent program).
- The cost of the image pane, measured with a ReleaseFast build and `time` in the child: `ztk::snapshot .` of an 800x600 window with 20 buttons is 8.3 ms, and `image create photo -data` of the result is 2.9 ms. A Debug build gives 135 ms for the snapshot.
- A click on a ztk button gives it the focus. The `type` and `key` tools take a `widget` argument for this reason.
- Open bug: a run of `dockyard --headless --exit-after-frames 3` did not end on the GitHub runner (60 s limit) and ends in 0.2 s locally. The cause is not known. CI runs only the build and the tests. If the bug occurs with ztk alone, file it as a ztk issue.

- The preview child has `file`, `channels` (for `source`), and `clock`, with the project folder as the root folder (`src/host.zig`).
- The tests run the installed `dockyard` program as the preview child (`DOCKYARD_EXE` in `build.zig`), in a new folder `/tmp/dockyard-test-*` for each test.
