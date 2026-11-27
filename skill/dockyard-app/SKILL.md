---
name: dockyard-app
description: Build a desktop app for a person in Tcl on ztk, check it with screenshots and clicks on a headless backend, and give them native program files for Linux, macOS, and Windows to download. Use when the person asks for a desktop app, a small GUI tool, or a program file that they can run on their computer.
---

# Build a desktop app with dockyard

ztk runs Tk 8.6 scripts. This skill has the `ztk` program for Linux, the ztk programs of the other targets, and the `dockyard` CLI in `bin/`. The CLI runs each step with one command. It needs no display and no network.

In the commands below, `SKILL` is the folder of this file.

## The steps

1. Make the project: `SKILL/bin/dockyard new my-app`. The app is `my-app/main.tcl`. Use a short name in lowercase with dashes. The name is the name of the program file.
2. Write the app in `main.tcl`. Other scripts load with `source other.tcl`. Put no `exit` in the app.
3. Run it: `SKILL/bin/dockyard run my-app`. Look at `my-app/shot.png`. A script error goes to stderr, and the exit status is not 0.
4. Check the behavior with a check script (below): `SKILL/bin/dockyard check my-app check.tcl`. Keep the check script outside the app folder.
5. Change the app, and do steps 3 and 4 again until the app works and looks right.
6. Build: `SKILL/bin/dockyard build my-app` for all the targets, or `SKILL/bin/dockyard build my-app x86_64-windows aarch64-macos` for some. The files are `my-app/build/TARGET/my-app`, with `.exe` for Windows. For macOS it is the app folder `my-app.app`: zip the folder for the download.
7. Give the person the program files of their platforms as downloads, and the screenshot.

Ask the person which platforms they use when the request does not say. The targets are `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos` (Apple silicon), `x86_64-windows`, and `aarch64-windows`.

## Tell the person these facts

- A program file is the ztk program with the app in it. It needs no install.
- On Linux, run `chmod +x my-app` first.
- On macOS, the app has an ad hoc signature and no signature from a known developer. Unzip it, right click `my-app.app` and select Open the first time, or run `xattr -dr com.apple.quarantine my-app.app`.
- Today only the Windows files show a window. The Linux files of this skill are static and have no Wayland backend, and the macOS files have no AppKit backend, because the skill builds them off a Mac. Each one stops with a message. Say this when the person asks for Linux or macOS. A person on Linux or macOS can build the app with dockyard or ztk on their own computer.
- The app has the `file`, `channels`, and `clock` capabilities, and no network and no program start.

## The tools of ztk in a check script

| Command | What it gives |
|---|---|
| `ztk::tree ?path?` | One list for each widget below the path (default `.`): the path, the class, x and y in the toplevel, the width, the height, and 1 when the widget is mapped. |
| `ztk::snapshot path` | A PNG image of the widget as base64 text. |
| `ztk::inject top motion x y` | A pointer motion. |
| `ztk::inject top press button x y`, `release button x y` | A button press or release. Send a motion first, then a press and a release, to click. |
| `ztk::inject top key keysym` | A key press and release. |
| `ztk::inject top text string` | Typed text. |

`event generate` does not update the hover state, so a generated click does not invoke a button. Use `ztk::inject` to click.

## A check script

`dockyard check` runs `main.tcl` and then the check script in one interpreter. The check script ends with `exit`. This check clicks the button `.go` of an app that counts in `::n`:

```tcl
update
foreach row [ztk::tree .] {
    lassign $row path class x y w h mapped
    if {$path eq ".go"} {
        set cx [expr {$x + $w / 2}]
        set cy [expr {$y + $h / 2}]
    }
}
ztk::inject . motion $cx $cy
ztk::inject . press 1 $cx $cy
ztk::inject . release 1 $cx $cy
update
puts "n = $::n"
exit
```

## Idioms

- Give each widget a short path that says what it is: `.toolbar.save`, `.form.name`.
- Use `-textvariable` and `-variable`, so the state is in variables that a check can read.
- Use `grid` for forms, `pack` for bars and stacks, and `place` for overlays.
- Use the `ttk::` widgets for a themed look.
- Keep the code short. The person reads it to check what the app can do.

The docs of ztk are at https://beetlebug.org/ztk/. The commands and their options are in https://beetlebug.org/ztk/api.json.
