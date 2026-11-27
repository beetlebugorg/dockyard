# The skill for Claude

`dockyard-app` is a skill for Claude. With it, Claude writes a desktop app in its own sandbox, checks it with screenshots and clicks, and gives you program files to download. You need no dockyard window and no install: ask Claude for an app in a chat.

> "Make me a small timer app with a start button and a list of laps. I use Windows."

Claude then:

1. makes the project and writes `main.tcl`,
2. runs it on the headless backend of ztk and looks at the screenshot,
3. clicks and types in the app with a check script, and fixes what is wrong,
4. builds the program file of each platform that you use, and gives you the files and a screenshot.

## Install it

1. Build the zip: `tools/skill.sh` writes `zig-out/dockyard-app.zip`.
2. In Claude, open the settings of the Skills, and upload the zip.

The zip has `SKILL.md`, the `dockyard` command-line tool, and the ztk program of each of the six targets. On 2026-11-26 the zip was 18,561,947 bytes. The upload limit is 30,000,000 bytes, and CI checks the size of each build. The skill also works in Claude Code: put the folder `skill/dockyard-app/` in `.claude/skills/` of a project or of your home folder.

No release of the zip is published yet. Build it from the source.

## The dockyard command of the skill

| Command | What it does |
|---|---|
| `dockyard new NAME` | Makes the folder `NAME` with a first `main.tcl`. |
| `dockyard run NAME` | Runs the app on the headless backend, and writes `NAME/shot.png`. A script error goes to stderr. |
| `dockyard check NAME CHECK.tcl` | Runs the app, then the check script in the same interpreter: clicks with `ztk::inject`, reads with `ztk::tree`. |
| `dockyard build NAME ?TARGET ...?` | Builds the program file of each target in `NAME/build/TARGET/`. With no target, all six. |

## What you get

| Your system | The file | The first run |
|---|---|---|
| Windows (x86-64 or arm64) | `NAME.exe` | Run it. It needs no install. |
| macOS (Apple silicon or Intel) | `NAME.app`, in a zip | The app has an ad hoc signature. Right-click it and select Open the first time, or run `xattr -dr com.apple.quarantine NAME.app`. |
| Linux (x86-64 or arm64) | `NAME` | `chmod +x NAME` first. |

The skill builds the programs off a Mac and off a Linux desktop, so today only the Windows programs of the skill open a window. A macOS program of the skill has no AppKit backend, and a Linux program of the skill has no Wayland backend: each one stops with a message. Build the app with dockyard on your own computer for a macOS or Linux window.

The app has the capabilities `file`, `channels`, and `clock`, and no network and no program start.
