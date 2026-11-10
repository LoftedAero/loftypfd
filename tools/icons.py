"""Draws the bitmaps the scripts use, so they can be made again.

    .venv/Scripts/python tools/icons.py

src/icons/gear-*.png  the settings button's gear in each theme's ink2,
                      drawn by both radios as one bitmap (a gear of filled
                      triangles cost EdgeTX a fifth of its frame budget)
src/ethos/icon.png    the Ethos tool's icon: an attitude indicator, as the
                      grayscale mask lcd.loadMask wants, in which dark is drawn

Development only: needs Pillow, which the radios never see.
"""
import math
import pathlib
import re

from PIL import Image, ImageDraw, ImageOps

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUPER = 8


def ink2(name):
    theme = (ROOT / "src" / "core" / "theme.lua").read_text(encoding="utf-8")
    table = theme[theme.index(name + " = {"):]
    r, g, b = re.search(r"ink2 = \{ (\d+), (\d+), (\d+) \}", table).groups()
    return int(r), int(g), int(b)


def gear(name, size=64):
    big = size * SUPER
    mask = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(mask)
    c, r = big / 2, big / 2 - SUPER
    root = 0.72
    pts = []
    step = 2 * math.pi / 8
    for i in range(8):
        a = i * step - math.pi / 2
        for frac, rad in ((-0.38, root), (-0.21, 1), (0.21, 1), (0.38, root)):
            t = a + frac * step
            pts.append((c + math.cos(t) * rad * r, c + math.sin(t) * rad * r))
    d.polygon(pts, fill=255)
    d.ellipse((c - root * r, c - root * r, c + root * r, c + root * r), fill=255)
    hole = 0.3 * r
    d.ellipse((c - hole, c - hole, c + hole, c + hole), fill=0)
    mask = mask.resize((size, size), Image.LANCZOS)
    img = Image.new("RGBA", (size, size), ink2(name) + (0,))
    img.putalpha(mask)
    out = ROOT / "src" / "icons" / ("gear-%s.png" % name)
    out.parent.mkdir(exist_ok=True)
    img.save(out)
    return out


def tool_icon(size=48):
    k = SUPER
    big = Image.new("L", (size * k, size * k), 0)
    d = ImageDraw.Draw(big)
    c = size * k / 2
    r = 20 * k
    d.ellipse((c - r, c - r, c + r, c + r), outline=255, width=3 * k)
    a = math.radians(-12)
    dx, dy = math.cos(a) * (r - 2 * k), math.sin(a) * (r - 2 * k)
    d.line((c - dx, c + 2 * k - dy, c + dx, c + 2 * k + dy), fill=255, width=3 * k)
    w = 9 * k
    d.line((c - w - 4 * k, c - 4 * k, c - 4 * k, c - 4 * k), fill=255, width=3 * k)
    d.line((c + 4 * k, c - 4 * k, c + w + 4 * k, c - 4 * k), fill=255, width=3 * k)
    d.ellipse((c - 2 * k, c - 6 * k, c + 2 * k, c - 2 * k), fill=255)
    out = ROOT / "src" / "ethos" / "icon.png"
    ImageOps.invert(big.resize((size, size), Image.LANCZOS)).save(out)
    return out


if __name__ == "__main__":
    for path in (gear("light"), gear("dark"), tool_icon()):
        print("wrote " + path.relative_to(ROOT).as_posix())
