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
| Current ztk | dockyard | Done: ztk fffc1cc (ztcl 821a3a7), with the photo fix of ztk PR 224 and the real clock of ztk PR 225, with `ztk bundle`, `ztk::terminal -shell` and `-command` on libghostty-vt, and `ztcl::vm` on macOS. |
| README and user docs (issue 11) | dockyard | Done: README, `docs/guide.md`, `docs/security.md`, `docs/faq.md`, and `tools/screenshots.sh` for `docs/images/`. The live replay page of issue 11 is not started. |
| Build button | dockyard, ztk | Done: `src/apps.zig` (`dockyard::build::run` calls `ztk.bundle.run`) and the bar of `dockyard.tcl`. `zig build -Druntimes=...` puts the ztk program of each target in `zig-out/lib/ztk/runtime/TARGET/`. ztk PR 229 fixes the build for aarch64-windows. |
| App list | dockyard | First form done: the Apps window lists the apps next to the project with their programs, with Launch and Open in dockyard. |
| History | dockyard | Not started. |
| Claude skill (issue 16) | dockyard | `skill/dockyard-app/` (SKILL.md and the `dockyard` CLI: new, run, check, build), `tools/skill.sh` (the zip with the ztk programs of all the targets, and the size check), `tools/skill-test.sh`, and the CI job `Skill (Linux)`. Not published: a release of the zip waits for the user. |
| Sandbox plan (issues 13 and 15) | dockyard | `docs/dev/vm.md`: the parts, the image, the network, the threat model, and 8 steps. |
| Egress proxy (step 1 of `vm.md`) | dockyard | Done: `src/proxy.zig`, the Tcl command `dockyard::proxy` (start, allow, events, and stop), with a relay test and a block test. CONNECT only. |
| microVM terminal (issue 13) | dockyard, ztcl | Linux KVM first form: `dockyard --sandbox DIR` runs the terminal pane on a PTY of a guest of `ztcl::vm`, over vsock, through the helper of `docs/dev/guest.md` (`src/guest/main.zig`, `src/sandbox.tcl`, `src/sandbox.zig`). The proxy port of the guest goes to `dockyard::proxy attach`. Waits for: the KVM shares (ztcl PR 385), `CONFIG_INET` in the guest kernel, the KVM thread fix (ztcl PR 436) in the ztcl of ztk, and the tools disk. macOS and Windows: not checked yet. |
| Sandbox monitor (issue 15) | dockyard | First form: `docs/dev/monitor.md`. The log outside the project (`src/monitor.zig`), the window and the terminal view in one program (`dockyard --monitor ?--tui?`, `src/monitor.tcl`), the rules of the blocked tray, and the sharing panel (Shares). Not started: the hooks and metrics of the agent program, the diff of each step, the replay. |

## Next steps

1. Step 2 of `docs/dev/vm.md`: the Buildroot tree in `os/` and the CI job for the base image. Resume: copy the layout of Printdeck OS (`os/` of the printdeck repository), with the kernel fragment of `vm.md` and ztcl `tools/vm-guest/kernel.fragment`. Build the binaries only, and read no GPL source.
2. Step 4 of `vm.md` on a Mac: `dockyard::vm` and the terminal pane in the guest. It waits for the PTY session of the ztcl guest agent.
3. Steps 5 to 7 of `vm.md` (issue 15): the monitor core on `dockyard::proxy events`, the two front ends, and the sharing panel. The core and the TUI can start on Linux now with the proxy events.
4. The history pane (spec section 6), the live replay page (issue 11), and `ztk::embed` (ztk `docs/dev/embed.md`).

## Notes

- The bridge: the agent program starts `dockyard --mcp` from `.mcp.json` in the project folder. That process connects to a Unix socket of the preview child at `$XDG_RUNTIME_DIR/dockyard-<hash of the project path>.sock` (or `/tmp/dockyard-<uid>-<hash>.sock`). The Zig code of the child opens the socket before main.tcl runs, and a native timer of the loop polls it every 20 ms. The Tcl script of the child still has no `socket` command. With `ztk::embed`, the parent can evaluate the requests directly.
- The `restart` tool ends the child with status 75, and the window script starts a new run.
- After an error in main.tcl, the child keeps running, so the `errors` tool can give the trace.
- dockyard writes `.mcp.json` and `CLAUDE.md` into a project that has none. `.mcp.json` has the full path of the dockyard program. The agent program asks the user to approve a server of a project file before it uses it (not checked here: the tests never run the agent program).
- The cost of the image pane, measured with a ReleaseFast build and `time` in the child: `ztk::snapshot .` of an 800x600 window with 20 buttons is 8.3 ms, and `image create photo -data` of the result is 2.9 ms. A Debug build gives 135 ms for the snapshot.
- A click on a ztk button gives it the focus. The `type` and `key` tools take a `widget` argument for this reason.
- The headless backend of the preview child and of `dockyard --headless` uses the clock of the system (`Headless.real_clock`, ztk PR 225). Before, the clock of the headless backend moved by the full timeout of each wait, so `after 1000` ran at once and the child used a full CPU core. `--exit-after-frames` keeps the clock of the tests.
- The image of the preview is a `ttk::label`. The classic `label` of ztk has no `-image` option.
- Open bug: a run of `dockyard --headless --exit-after-frames 3` did not end on the GitHub runner (60 s limit) and ends in 0.2 s locally. The cause is not known. CI runs only the build and the tests. If the bug occurs with ztk alone, file it as a ztk issue.

- The preview child has `file`, `channels` (for `source`), and `clock`, with the project folder as the root folder (`src/host.zig`).
- The tests run the installed `dockyard` program as the preview child (`DOCKYARD_EXE` in `build.zig`), in a new folder `/tmp/dockyard-test-*` for each test.
- The ztk programs of other targets come from a build on another system. A Linux program of another target has the direct and the headless backends (musl, static). A macOS program made off a Mac has only the headless backend, because the AppKit backend links the macOS SDK. A Windows program has the Win32 backend from any system.
- `dockyard::apps::spawn` does not wait for the program, so an ended program stays a zombie process until dockyard ends.
