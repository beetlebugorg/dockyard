# This project

This folder is a desktop app in Tcl for ztk. dockyard shows the app in its preview pane and runs `main.tcl` again after each change of a file. The first script is `main.tcl`. Other files load with `source /file.tcl`.

## The preview

- The root folder of `file`, `open`, and `source` is this folder. So `/data.txt` is the file `data.txt` here.
- The preview has the `file`, `channels`, and `clock` capabilities. It has no `exec` and no `socket`.
- Each change of a file starts a new run of `main.tcl`, so the state of the app starts again.

## ztk

ztk runs Tk scripts. Write the script as for Tk 8.6 `wish`:

- Widgets: `frame`, `label`, `button`, `checkbutton`, `radiobutton`, `entry`, `spinbox`, `scale`, `scrollbar`, `listbox`, `canvas`, `labelframe`, `message`, `menu`, `menubutton`, `toplevel`, and the simple `ttk` widgets.
- Geometry: `pack`, `grid`, and `place`.
- Events: `bind`, `after`, `event generate`, and `<MouseWheel>` as in Tk 8.7.
- Missing today: `text`, `panedwindow`, `ttk::notebook`, `ttk::treeview`, the dialogs such as `tk_messageBox`, `option`, `selection`, and `package`.
- The theme gives the colors, the borders, and the padding. Set a color only when the design needs it. `ttk::style configure` changes the look of the `ttk` widgets.

## The tools of the dockyard MCP server

Use these tools to see the app. Do not guess how it looks.

| Tool | Use |
|---|---|
| `errors` | The errors since the last call, with the Tcl traces. Call it after each change. |
| `screenshot` | A PNG of the window, or of one widget with `widget`. |
| `widgets` | The widget tree: the path, the class, x y width height, the mapped flag, and the text. |
| `eval` | Run Tcl in the app, for example `set ::count` or `.b invoke`. |
| `click` | Press and release a mouse button at x y of a toplevel. Get the point from `widgets`. |
| `type` | Type text into the widget with the focus, or into `widget`. |
| `key` | Press one key, for example `Return`, `Tab`, or `Control-a`. |
| `scroll` | Turn the mouse wheel at x y. A negative `delta` scrolls down. |
| `log` | The output of `puts` since the last call. |
| `restart` | Run `main.tcl` again. |

A good cycle for each change:

1. Write the change.
2. Call `errors`. Fix each error.
3. Call `screenshot`, and check the result.
4. Test the behavior with `click`, `type`, or `eval`.
