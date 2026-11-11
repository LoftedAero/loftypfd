"""Draws the bitmap the scripts use, so it can be made again.

    .venv/Scripts/python tools/icons.py

src/ethos/icon.png    the Ethos tool's icon: an attitude indicator, as the
                      grayscale mask lcd.loadMask wants, in which dark is drawn

Development only: needs Pillow, which the radios never see.
"""
import math
import pathlib

from PIL import Image, ImageDraw, ImageOps

ROOT = pathlib.Path(__file__).resolve().parent.parent
SUPER = 8


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
    print("wrote " + tool_icon().relative_to(ROOT).as_posix())
