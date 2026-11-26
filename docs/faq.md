# FAQ

## What do I need to use dockyard?

Zig 0.17.0 to build dockyard, and an agent program for the terminal pane. The default agent program is Claude Code (`claude`). dockyard runs any other program with `--agent PROGRAM`.

## Does dockyard include Claude Code?

No. Install it with `npm install -g @anthropic-ai/claude-code`. When the `PATH` does not have `claude`, the terminal pane runs your shell and shows this command.

## Which platforms does dockyard run on?

CI builds and tests dockyard on Linux, with the headless backend. On Linux, the window uses Wayland. ztk has an AppKit backend for macOS. The macOS build of dockyard is not checked in CI.

## What language are the apps in?

Tcl, for ztk. ztk runs Tk 8.6 scripts. `CLAUDE.md` in each project lists the widgets that ztk has today.

## Is my code sent to a server?

dockyard does not send your code to a server. The agent program sends your messages, and the files that it reads, to its own service. Read the terms of the agent program.

## Who owns the apps that I make?

You do. dockyard is under the AGPL, version 3, with an output exception (`LICENSE-EXCEPTION.md`). The exception lets you license the apps that you make under any terms that you choose.

## Why does the preview start again after each change?

A new run of `main.tcl` is the simplest way to show the current code. A reload with no restart is in the plan (`docs/dev/spec.md`, section 4).

## Can the app in the preview harm my computer?

The preview has no `exec` and no `socket`, and it sees only the project folder. Read [security.md](security.md). The terminal pane is not a sandbox.
