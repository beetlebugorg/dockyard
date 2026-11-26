# dockyard: spec (draft 1)

Date: 2026-11-25. Status: idea, not started. Name: **dockyard** (user, 2026-11-25). A separate repository for the app. Some features go first into ztcl and ztk (section 8).

## 1. Goal

A ztk desktop app that builds apps with an AI agent, and then manages them.

1. You chat with Claude Code in a terminal inside the app.
2. Claude builds a ztcl/ztk app. The app shows the result live as Claude writes it. You watch it grow, and you iterate.
3. You click **Build**. The app makes a native static binary for each platform that you select.
4. dockyard keeps all your apps: it opens, rebuilds, updates, and launches them. It is your own super app.

dockyard is a ztk app. Later versions are partly built with dockyard.

## 2. The window

Three panes, which the user can resize:

- **Terminal** (left): Claude Code (`claude`) runs in a `ztk::terminal` widget.
- **Preview** (right): the app under construction runs live.
- **Project bar** (top or side): the app list, the history of the project, the Build button, the platforms, and the capabilities of the app.

## 3. The terminal: Ghostty in ztk

- Ghostty is written in Zig. Its terminal core is being split into an embeddable library, `libghostty`, starting with the VT parser and the terminal state. Check the state and the stability of its API before the work starts.
- ztk embeds the terminal **state** from libghostty, and ztk draws the grid itself. So the terminal uses the ztk renderers (Vulkan, Metal, D3D12, the web), the ztk fonts and themes, and ztk animation. Ghostty's own renderer is not used.
- The widget: `ztk::terminal .t -command {claude} -cwd $dir`, with scrollback, selection, copy and paste, links, the keyboard protocols, resize, and the colors of the ztk theme.
- ztcl gives a pseudo-terminal (PTY) to run the child process (section 8).

## 4. The live preview

- The preview runs the app in a child interpreter with a sandbox: the capabilities that the app declares, and `ztk::limit` for steps and memory. A half-written app cannot hang dockyard or reach outside its folder.
- A file watcher sees each change that Claude writes. dockyard evaluates the changed files again in the child interpreter, with no restart. Tcl makes this cheap: a `proc` is defined again, and the widgets are built again.
- Keep the state when it is possible: the preview keeps the values of variables that the app marks as state. A full restart is one key away.
- An error shows in the preview pane with the file and the line, and goes to Claude too (section 5).

## 5. The bridge to Claude Code (MCP)

dockyard runs a small MCP server that Claude Code connects to. So Claude sees what it builds, and does not guess.

Tools:

- `screenshot`: an image of the preview (or of one widget).
- `widgets`: the widget tree with the classes, the geometry, and the key options.
- `eval`: run Tcl in the preview interpreter.
- `click`, `type`, `key`, `scroll`: send events to the preview.
- `errors` and `log`: the errors and the output of the preview since the last call.
- `restart`: restart the preview.

Each project gets a `CLAUDE.md` (or a skill) that teaches the ztk API, the conventions of dockyard, and these tools. So Claude writes idiomatic ztk from the first message.

## 6. History

- Each project is a git repository.
- dockyard commits after each change that Claude makes, with the user message as the subject.
- The history pane shows the versions as a list with a small screenshot each. "Undo that" and "go back to the version with the blue header" are a click.

## 7. Build and manage

- **Build** uses `ztcl build` (static binaries, the embedded file system, cross-compilation: ztcl #40) and the app bundles of ztk (#56 macOS .app, #59 Windows .exe, #60 Linux). One click makes a native app for each selected platform, from any host.
- **The app list** (the super app):
  - each app with its source, its history, and its built binaries;
  - open, rebuild, update, launch, and delete;
  - the capabilities that each app requests, shown before a build, so the user sees what each app can do;
  - later: share an app (a link to its binary or its source), and update the apps when ztcl or ztk changes.

## 8. Features that ztcl and ztk need first

These are useful without dockyard. Each gets an issue in its own repository.

**ztk**

1. `ztk::terminal`: a terminal widget on the libghostty VT core, drawn by ztk.
2. Screenshot of a window or of one widget to a PNG, from Tcl (`ztk::snapshot`).
3. A widget tree dump with geometry (`winfo` covers part of it; add one call that returns the whole tree).
4. Event injection into a window from Tcl, for tests and for the bridge (`event generate` covers part of it; check pointer and key events end to end).
5. A child interpreter that owns a ztk window inside a pane of the parent app (embedding: Tk's `-container` and `-use` in spirit), with the sandbox of the child.
6. treeview, text, panedwindow, and notebook (Stage 2 tasks 13, 15, 16).

**ztcl**

1. A PTY: spawn a child process on a pseudo-terminal, with resize, on Linux, macOS, and Windows (ConPTY). It is behind the `exec` capability.
2. A file watcher (inotify, FSEvents or kqueue, ReadDirectoryChangesW) on the event loop.
3. An MCP server library over stdio and HTTP (it uses the JSON batteries, and HTTP from #27).
4. `ztcl build` with static binaries, the embedded file system, and cross-compilation (#40).
5. A small git interface: run `git` through `exec`, or a library later.

## 9. Build order

Each step is useful alone and makes a good demo.

1. ztcl PTY, then `ztk::terminal`.
2. The live preview with reload in a sandboxed child interpreter (ztcl file watcher, ztk embedding).
3. The MCP bridge (ztk snapshot, tree dump, event injection; ztcl MCP library).
4. The Build button (ztcl #40, ztk #56, #59, #60).
5. The app list and the history.

## 10. Open questions

1. The libghostty API: is the VT core stable enough now, and what is its license? (Ghostty is MIT.)
2. Does dockyard ship Claude Code, or does it expect the user to install it? (Expect it: dockyard finds `claude` on the PATH and shows how to install it.)
3. One project per window, or tabs?
4. Where do the projects live? (Suggested: `~/dockyard/<app>/`.)
5. Does a built app keep a link back to dockyard for updates?
6. The license of dockyard.
