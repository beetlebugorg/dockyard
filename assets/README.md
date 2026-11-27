# The logo and the icons

`logo.svg` is the source of each icon. `python3 -I tools/icons.py` makes the other files with `rsvg-convert`, and writes `src/icon.tcl` (the icon of the window and the logo of the bar).

| File | Use |
|---|---|
| `icon/dockyard.icns` | macOS, 16 to 1,024 pixels |
| `icon/dockyard.ico` | Windows, 16 to 256 pixels |
| `icon/dockyard-N.png` | Linux, for `dockyard.desktop`: 512, 256, 128, 64, 48, 32, and 16 pixels, in `share/icons/hicolor/NxN/apps/dockyard.png` |
| `icon/favicon.svg`, `icon/favicon.ico` | The docs |
| `icon/social.png` | The social preview of the repository and the docs, 1,280 by 640 pixels |

The mark is a shipping container above a wave: an app in its box at the dock. It has three shapes and no text, so it reads at 16 pixels. The colors are blue `#1d4ed8`, amber `#f59e0b`, and white, and the tile is the same on a light and a dark background.
