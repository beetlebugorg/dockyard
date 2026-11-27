#!/usr/bin/env python3
"""Makes the icon files of dockyard from assets/logo.svg.

rsvg-convert renders the SVG to a PNG of each size. This script then
packs the PNGs: an .icns file is the magic "icns", the total length, and
one entry for each size (a 4-byte type, the length, and the PNG bytes).
An .ico file is a 6-byte header, one 16-byte directory entry for each
size, and the PNG bytes of each image (Windows Vista and later read PNG
images in an .ico file). The social image is a 1280x640 SVG with the
logo and the name, rendered the same way.

It also writes src/ui/icon.tcl, the icon of the window and the logo of
the bar as base64 PNG data.

usage: python3 -I tools/icons.py
"""
import base64
import pathlib
import struct
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOGO = ROOT / "assets" / "logo.svg"
OUT = ROOT / "assets" / "icon"
ICNS = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
        ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
ICO = [16, 24, 32, 48, 64, 128, 256]
LINUX = [512, 256, 128, 64, 48, 32, 16]


def render(svg, size, height=None):
    """Gives the PNG bytes of an SVG file at a size."""
    with tempfile.NamedTemporaryFile(suffix=".png") as f:
        subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(height or size), "-o", f.name, str(svg)], check=True)
        return pathlib.Path(f.name).read_bytes()


def icns(pngs):
    body = b"".join(kind.encode() + struct.pack(">I", 8 + len(pngs[size])) + pngs[size] for kind, size in ICNS)
    return b"icns" + struct.pack(">I", 8 + len(body)) + body


def ico(pngs, sizes=ICO):
    head = struct.pack("<HHH", 0, 1, len(sizes))
    offset = 6 + 16 * len(sizes)
    entries, data = b"", b""
    for size in sizes:
        png = pngs[size]
        # A width or height of 256 is 0 in the directory entry.
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(png), offset + len(data))
        data += png
    return head + entries + data


def social():
    """The social image of the repository and the docs: 1280x640."""
    logo = LOGO.read_text().split("\n", 1)[1].rsplit("</svg>", 1)[0]
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="640" viewBox="0 0 1280 640">
  <rect width="1280" height="640" fill="#0f172a"/>
  <svg x="96" y="200" width="240" height="240" viewBox="0 0 64 64">{logo}</svg>
  <text x="390" y="315" font-family="Inter, DejaVu Sans, sans-serif" font-size="112" font-weight="700" fill="#ffffff">dockyard</text>
  <text x="394" y="390" font-family="Inter, DejaVu Sans, sans-serif" font-size="34" fill="#cbd5e1">Build desktop apps by chatting with Claude Code.</text>
  <text x="394" y="438" font-family="Inter, DejaVu Sans, sans-serif" font-size="34" fill="#cbd5e1">A live preview, and one program for each OS.</text>
</svg>
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sizes = sorted({s for _, s in ICNS} | set(ICO) | set(LINUX))
    pngs = {s: render(LOGO, s) for s in sizes}
    (OUT / "dockyard.icns").write_bytes(icns(pngs))
    (OUT / "dockyard.ico").write_bytes(ico(pngs))
    for s in LINUX:
        (OUT / f"dockyard-{s}.png").write_bytes(pngs[s])
    (OUT / "dockyard-1024.png").write_bytes(pngs[1024])
    (OUT / "favicon.svg").write_text(LOGO.read_text())
    (OUT / "favicon.ico").write_bytes(ico(pngs, [16, 32, 48]))
    # The icon of the window and the logo of the bar, for src/main.zig.
    tcl = ROOT / "src" / "ui" / "icon.tcl"
    tcl.write_text("# Made by tools/icons.py from assets/logo.svg: the icon of the window\n"
                   "# (64 pixels) and the logo of the bar (20 pixels), as base64 PNG data.\n"
                   "namespace eval ::dockyard {}\n"
                   f"set ::dockyard::icon64 {base64.b64encode(pngs[64]).decode()}\n"
                   f"set ::dockyard::icon20 {base64.b64encode(render(LOGO, 20)).decode()}\n")
    svg = OUT / "social.svg"
    svg.write_text(social())
    (OUT / "social.png").write_bytes(render(svg, 1280, 640))
    for p in sorted(OUT.iterdir()):
        print(f"{p.stat().st_size:>9,} {p.relative_to(ROOT)}")


main()
