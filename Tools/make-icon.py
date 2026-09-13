#!/usr/bin/env python3
"""Builds Resources/Kylmora.icns from the K mark.

The mark (Resources/Icon/kylmora-mark.png, transparent background) is set on a
white rounded square laid out on Apple's 1024-point icon grid: an 824-point
tile centred on the canvas, the standard ~22.4% corner radius, and a soft
shadow beneath, which is how macOS expects an app icon to sit in the Dock next
to the system's own. The composite is rendered once at 1024 and downsampled to
the ten sizes `iconutil` needs.

    python3 Tools/make-icon.py            # writes Resources/Kylmora.icns
                                          # and Resources/Icon/kylmora-icon-1024.png
Requires Pillow (pip install pillow) and Xcode's iconutil.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    sys.exit("make-icon: Pillow is required: python3 -m pip install pillow")

ROOT = Path(__file__).resolve().parent.parent
MARK = ROOT / "Resources" / "Icon" / "kylmora-mark.png"
COMPOSITE = ROOT / "Resources" / "Icon" / "kylmora-icon-1024.png"
ICNS = ROOT / "Resources" / "Kylmora.icns"

CANVAS = 1024          # Apple's grid
TILE = 824             # the rounded square
RADIUS = 0.2237 * TILE # Apple's corner radius, as a share of the tile
SS = 4                 # supersampling for clean edges
GLYPH_HEIGHT = 0.68    # the K's height as a share of the tile


def rounded_tile(size, radius, scale):
    mask = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1), radius=radius * scale, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def vertical_gradient(size, top, bottom):
    tile = Image.new("RGBA", (size, size))
    px = tile.load()
    for y in range(size):
        t = y / (size - 1)
        colour = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(size):
            px[x, y] = colour
    return tile


def build_composite():
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    inset = (CANVAS - TILE) // 2
    mask = rounded_tile(TILE, RADIUS, SS)

    # Shadow: the tile's silhouette, blurred and nudged down.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 70), (inset, inset + 14, inset + TILE, inset + TILE + 14), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(20))
    canvas.alpha_composite(shadow)

    # Tile: white fading to a cool off-white, so it reads as a surface, not a hole.
    tile = vertical_gradient(TILE, (255, 255, 255), (241, 244, 250))
    canvas.paste(tile, (inset, inset), mask)

    # Mark: trimmed to its own bounds, scaled to the tile, centred.
    mark = Image.open(MARK).convert("RGBA")
    mark = mark.crop(mark.getbbox())
    target_h = round(TILE * GLYPH_HEIGHT)
    target_w = round(mark.width * target_h / mark.height)
    mark = mark.resize((target_w, target_h), Image.LANCZOS)
    canvas.alpha_composite(mark, ((CANVAS - target_w) // 2, (CANVAS - target_h) // 2))
    return canvas


def write_icns(composite):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "Kylmora.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = points * scale
                name = f"icon_{points}x{points}" + ("@2x" if scale == 2 else "") + ".png"
                composite.resize((px, px), Image.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)], check=True)


if __name__ == "__main__":
    if shutil.which("iconutil") is None:
        sys.exit("make-icon: iconutil not found; install Xcode Command Line Tools")
    composite = build_composite()
    composite.save(COMPOSITE)
    write_icns(composite)
    print(f"wrote {ICNS.relative_to(ROOT)} and {COMPOSITE.relative_to(ROOT)}")
