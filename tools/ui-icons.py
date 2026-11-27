#!/usr/bin/env python3
"""Makes src/ui/ui-icons.tcl from the SVG files in assets/ui/.

Each SVG draws with "currentColor" on a 16x16 grid. This script puts
one color of each tone in place of currentColor, and rsvg-convert
renders a PNG of 16 pixels. src/ui/ui-icons.tcl has the base64
data of each PNG in the dict ::dockyard::ui::icondata, with the key
"name tone scheme size". The window loads the images of its color
scheme only (src/ui/theme.tcl, proc ::ui::icon).

usage: python3 -I tools/ui-icons.py
"""
import base64
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "ui"
OUT = ROOT / "src" / "ui" / "ui-icons.tcl"

# The tones of each scheme. They match the variables of src/ui/theme.tcl.
TONES = {
    "light": {"muted": "#5f6672", "fg": "#1f2329", "white": "#ffffff", "accent": "#2563eb",
              "ok": "#15803d", "warn": "#b45309", "danger": "#dc2626"},
    "dark": {"muted": "#a1a7b3", "fg": "#e6e8ec", "white": "#ffffff", "accent": "#60a5fa",
             "ok": "#4ade80", "warn": "#fbbf24", "danger": "#f87171"},
}
# The status tones are made only for the icons that use them.
STATUS = {"check": ["ok"], "error": ["danger"], "blocked": ["danger"], "shield": ["warn"],
          "shieldcheck": ["ok"], "globe": ["accent"], "bolt": ["accent"], "build": ["white", "warn"], "chevron": ["white"], "export": ["white"],
          "play": ["ok", "white"], "stop": ["danger"], "prompt": ["accent"], "activity": ["white"],
          "apps": ["white"], "terminal": ["white"]}


def render(svg: str, size: int) -> bytes:
    return subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size)],
                          input=svg.encode(), capture_output=True, check=True).stdout


def main() -> None:
    lines = ["# Made by tools/ui-icons.py from assets/ui/*.svg: the icons of the",
             "# window as base64 PNG data, with the key \"name tone scheme size\".",
             "namespace eval ::dockyard::ui {}",
             "set ::dockyard::ui::icondata {"]
    for path in sorted(SRC.glob("*.svg")):
        name = path.stem
        svg = path.read_text()
        for scheme, tones in TONES.items():
            for tone in ["muted", "fg"] + STATUS.get(name, []):
                colored = svg.replace("currentColor", tones[tone])
                for size in (16,):
                    data = base64.b64encode(render(colored, size)).decode()
                    lines.append(f"    {{{name} {tone} {scheme} {size}}} {data}")
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n")
    print(OUT, OUT.stat().st_size, "bytes")


main()
