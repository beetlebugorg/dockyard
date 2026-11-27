# Agent instructions

dockyard is a ztk desktop app. It runs an agent program in a terminal pane, shows the app under construction in a live preview, builds static binaries, and keeps a list of the apps. It uses ztcl and ztk, and has no other dependency.

Read these pages before you work:

1. [WRITING.md](WRITING.md), before you write code comments, commits, or PRs.
2. [docs/dev/spec.md](docs/dev/spec.md), the goal and the build order.
3. [docs/dev/status.md](docs/dev/status.md), the state of each step and the next step.

Put plans, task lists, reports, and limits in `docs/dev/`.

## Where the code goes

[docs/dev/architecture.md](docs/dev/architecture.md) has the map of `src/` (app, ui, sandbox, audit, guest), the rules between the modules, and the folder for each kind of new feature. Read it before you add a file.

The CPU limit of ztcl is the compute limit, and it counts compute units. Use these terms in code, docs, and messages.

## Commands

Use Zig 0.17.0. Run each build, test, and run command under a memory cap:

```sh
systemd-run --user --scope -q -p MemoryMax=4G -p MemorySwapMax=0 -- <command>
```

| Command | What it does |
|---|---|
| `zig build` | Builds `zig-out/bin/dockyard`. |
| `zig build test` | Runs the unit tests and the headless script tests. |
| `zig build test-bin` | Installs the test program as `zig-out/bin/test`, to run it with `timeout`. |
| `zig-out/bin/dockyard [--headless] [--agent PROGRAM] [project folder]` | Runs the app. |

## Rules

1. Run `zig build test` before each commit. The tests must pass.
2. Add no dependency other than ztcl, ztk, and the Zig standard library. A feature that dockyard needs from ztcl or ztk goes into that repository first, with its own PR.
3. Copy no code from a project with a GPL, LGPL, or AGPL license. Credit each source in `docs/references/`.
4. The tests never run the agent program. They use a shell or a small fake program.
5. The preview runs a project with only the capabilities that the project declares. The terminal pane has the `exec` capability, and it is outside the sandbox. Do not describe it as sandboxed.
6. Start each source file with a `//!` comment that explains its algorithm.
7. Keep local paths and private data out of the repository.
8. Stop only your own processes, by PID. Do not open a window on the live desktop session in a test.

## Commits and merges

- Follow the commit rules in WRITING.md.
- Add no attribution lines, co-author lines, or session links.
- Merge by rebase only. Keep merge commits out of PR branches.
