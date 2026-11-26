# User guide

This guide tells you how to use dockyard. dockyard is a desktop app. You chat with an agent program in a terminal pane, and the agent program writes a ztk app. The preview pane shows the app while the agent program writes it.

## Start dockyard

Give the folder of a project:

```sh
dockyard ~/dockyard/my-app
```

With no folder, dockyard uses the current folder. A project is a folder with a git repository. The first script of the app is `main.tcl`.

The flags:

| Flag | What it does |
|---|---|
| `--agent PROGRAM` | Runs `PROGRAM` in the terminal pane. The default is `claude` from the `PATH`. |
| `--dark` | Uses the dark color scheme. |
| `--headless` | Uses the headless backend. The window is not on the screen. |
| `--exit-after-frames N` | Exits after `N` frames. |
| `--exit-after-ms N` | Exits `N` ms after the start. |
| `--screenshot FILE.png` | With `--headless`: writes the last frame to `FILE.png` at the exit. |

## The window

The window has two panes:

- The terminal pane, on the left, runs the agent program in the project folder.
- The preview pane, on the right, runs `main.tcl` of the project.

### The terminal pane

The terminal pane is a `ztk::terminal` widget. It runs `claude` when the `PATH` has it. When the `PATH` does not have `claude`, the pane runs your shell and shows the install command. Type `exit` after the install, and dockyard starts `claude`.

When the program ends, press Return to start it again.

The program in the terminal pane runs with the full power of your user. Read [security.md](security.md).

### The preview pane

The preview pane runs `main.tcl` in a child process (`dockyard --run main.tcl --headless`). The pane shows the image of the window of the child, and sends your clicks and keys to it.

- The file watcher sees each change in the project folder. 150 ms after the last change, the pane starts the child again. Changes in `.git` do not start the child.
- The output of the app (`puts`) and its errors show below the image.
- The Restart button starts the child again.
- The size of the pane is the size of the window of the child.

A new run starts the state of the app again.

## The MCP tools

dockyard writes two files into a project that does not have them:

- `.mcp.json` tells the agent program to start `dockyard --mcp`, the MCP server of dockyard.
- `CLAUDE.md` tells the agent program about ztk, the preview, and the tools.

A file that exists stays as it is. The agent program asks you to approve the server of `.mcp.json` before it uses it.

The MCP server connects to the preview child. The tools:

| Tool | What it does |
|---|---|
| `screenshot` | Gives a PNG image of the preview window, or of one widget. |
| `widgets` | Gives the widget tree, with the class, the geometry, and the text of each widget. |
| `eval` | Runs Tcl in the preview interpreter. |
| `click` | Presses and releases a mouse button at a point. |
| `type` | Types text into the widget with the focus, or into a given widget. |
| `key` | Presses one key, for example `Return` or `Control-a`. |
| `scroll` | Turns the mouse wheel at a point. |
| `errors` | Gives the errors since the last call, with the Tcl traces. |
| `log` | Gives the output of the app since the last call. |
| `restart` | Runs `main.tcl` again. |

With these tools, the agent program gets images of the app and tests it.

## Build

The Build button is not in dockyard yet. [docs/dev/status.md](dev/status.md) has its state.

## The app list

The app list is not in dockyard yet. [docs/dev/status.md](dev/status.md) has its state.
