#!/usr/bin/env python3
"""Generates Resources/dmg-background.tiff for the installer disk image.

A soft light background with an arrow pointing from where the app icon sits
toward the Applications shortcut, so the drag-to-install gesture is obvious.
Rendered at 1x (620x420) and 2x and combined into a HiDPI TIFF so the window
stays a fixed size and the image is crisp on Retina.
Requires Pillow (pip install pillow) and macOS `tiffutil`.
"""
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("make-dmg-background: Pillow is required: python3 -m pip install pillow")

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "dmg-background.tiff"

W, H = 620, 420           # window size in points
TOP = (249, 250, 253)     # near-white
BOTTOM = (231, 235, 244)  # faint cool grey
ARROW = (156, 167, 190)   # muted blue-grey

# Icon centres (points) — kept in sync with Tools/dmg-settings.py.
APP_X, APPS_X, ICON_Y = 165, 455, 200


def render(scale: int) -> Image.Image:
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h))
    draw = ImageDraw.Draw(img)

    # Vertical gradient, one row at a time.
    for y in range(h):
        t = y / (h - 1)
        colour = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
        draw.line([(0, y), (w, y)], fill=colour)

    # Arrow from just right of the app icon to just left of Applications.
    y = ICON_Y * scale
    x0 = (APP_X + 95) * scale
    x1 = (APPS_X - 95) * scale
    shaft = max(3, 7 * scale)
    head = 22 * scale
    draw.line([(x0, y), (x1 - head * 0.7, y)], fill=ARROW, width=shaft)
    draw.polygon(
        [(x1, y), (x1 - head, y - head * 0.6), (x1 - head, y + head * 0.6)],
        fill=ARROW,
    )
    return img


one = ROOT / "Resources" / "_dmg-bg-1x.png"
two = ROOT / "Resources" / "_dmg-bg-2x.png"
render(1).save(one)
render(2).save(two)
subprocess.run(
    ["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(OUT)], check=True
)
one.unlink()
two.unlink()
print(f"wrote {OUT.relative_to(ROOT)}")
