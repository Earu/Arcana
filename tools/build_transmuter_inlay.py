#!/usr/bin/env python3
"""Generate the transmuter slab inlay artwork and pack it as a mipped DXT5 VTF.

The linework used to be flat brass strip meshes on the slab top; as a texture it
gets antialiased edges, mip filtering at glancing angles (see png_to_vtf.py) and
room for finer detail. The art is white-on-transparent: the entity tints it gold
through $color2 at draw time, the same pipeline as the brass meshes.

The design mirrors the transmuter menu: an offering circle and a return circle
(each with the menu's 12 tick marks) engraved under the two scale pans, twin
rails running to the column fulcrum, and the stream's phrase arced around each
station in Pulsian, the addon's runic face.

Coordinates mirror the entity: the slab top is 42 x 70 units, texture u runs
along the long axis (entity y, -35..35), v along the short axis (entity x,
-21..21). Drawing happens isotropically at supersample resolution, then a
non-uniform Lanczos resize to the square texture bakes the aspect mapping.

Usage:
    python3 tools/build_transmuter_inlay.py
    -> materials/arcana/transmuter_inlay.vtf
"""

import math
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFont

from png_to_vtf import png_to_vtf

REPO_ROOT = Path(__file__).resolve().parent.parent
PULSIAN = REPO_ROOT / "resource" / "fonts" / "pulsian.ttf"

LONG, SHORT = 70.0, 42.0
SS = 4096 / LONG                 # supersample px per unit, isotropic
CANVAS = (4096, round(SHORT * SS))
FINAL = (1024, 1024)
WHITE = (255, 255, 255, 255)

STROKE_RECT = 0.56
STROKE_FINE = 0.45

# station circles sit under the pans (entity y = +-26 on the centre line);
# the border rects part around them, so the two designs interlock
STATION_Y = 25.2
STATION_R = 6.2
RUNE_R = 7.7
RUNE_H = 1.9
BREAK_R = 9.4
PHRASE = "AEQUILIBRIUM OMNIA REPENDIT"


def px(ex, ey):
    """Entity (x short, y long) -> canvas pixel."""
    return ((ey + LONG / 2) * SS, (ex + SHORT / 2) * SS)


def upx(units):
    return max(1, round(units * SS))


def dot(draw, ex, ey, r):
    x, y = px(ex, ey)
    rp = r * SS
    draw.ellipse([x - rp, y - rp, x + rp, y + rp], fill=WHITE)


def rect(draw, hx, hy, stroke):
    half = stroke / 2
    x0, y0 = px(-hx - half, -hy - half)
    x1, y1 = px(hx + half, hy + half)
    draw.rectangle([x0, y0, x1, y1], outline=WHITE, width=upx(stroke))


def ring(draw, cx, cy, r, stroke):
    half = stroke / 2
    x0, y0 = px(cx - r - half, cy - r - half)
    x1, y1 = px(cx + r + half, cy + r + half)
    draw.ellipse([x0, y0, x1, y1], outline=WHITE, width=upx(stroke))


def seg(draw, a, b, stroke):
    draw.line([px(*a), px(*b)], fill=WHITE, width=upx(stroke))
    dot(draw, a[0], a[1], stroke / 2)
    dot(draw, b[0], b[1], stroke / 2)


def station(img, draw, cy):
    """One working circle: rim, the menu's 12 ticks, and the runic arc."""
    ring(draw, 0, cy, STATION_R, STROKE_FINE)

    for k in range(12):
        a = k * math.pi / 6
        c, s = math.cos(a), math.sin(a)
        seg(draw, (c * (STATION_R - 1.3), cy + s * (STATION_R - 1.3)),
            (c * (STATION_R - 0.25), cy + s * (STATION_R - 0.25)), STROKE_FINE * 0.75)

    dot(draw, 0, cy, 0.5)

    # phrase arced around the rim; drawn per glyph, rotated so its top points
    # away from the centre.  Pulsian glyphs occupy well under half the em, so
    # the point size is scaled from a measured reference to hit RUNE_H.
    ref = ImageFont.truetype(str(PULSIAN), 120)
    rb = ref.getbbox("A")
    font = ImageFont.truetype(str(PULSIAN), round(RUNE_H * SS * 120 / max(1, rb[3] - rb[1])))
    n = len(PHRASE)

    for i, ch in enumerate(PHRASE):
        if ch == " ":
            continue

        a = -math.pi / 2 + (i / n) * math.pi * 2
        gx, gy = px(math.cos(a) * RUNE_R, cy + math.sin(a) * RUNE_R)

        bbox = font.getbbox(ch)
        gw, gh = bbox[2] - bbox[0], bbox[3] - bbox[1]
        if gw < 1 or gh < 1:
            continue

        pad = 8
        tile = Image.new("RGBA", (gw + pad * 2, gh + pad * 2), (0, 0, 0, 0))
        ImageDraw.Draw(tile).text((pad - bbox[0], pad - bbox[1]), ch, font=font, fill=WHITE)
        # canvas y grows toward +entity x; rotate so the glyph top faces outward
        tile = tile.rotate(-math.degrees(a) - 90, expand=True, resample=Image.BICUBIC)
        img.alpha_composite(tile, (round(gx - tile.width / 2), round(gy - tile.height / 2)))


def main():
    img = Image.new("RGBA", CANVAS, (0, 0, 0, 0))

    # borders on their own layer so gaps can be punched where the stations pass
    border = Image.new("RGBA", CANVAS, (0, 0, 0, 0))
    bdraw = ImageDraw.Draw(border)

    rect(bdraw, 17.5, 31.5, STROKE_RECT)
    rect(bdraw, 15.8, 29.8, STROKE_RECT)

    # corner ticks where the two border rects meet
    for sx in (-1, 1):
        for sy in (-1, 1):
            x, y = 16.65 * sx, 30.65 * sy
            a = math.atan2(-sy, -sx)
            p = (x + math.cos(a) * 1.35, y + math.sin(a) * 1.35)
            seg(bdraw, (x, y), p, STROKE_FINE * 0.8)

    mask = Image.new("L", CANVAS, 255)
    mdraw = ImageDraw.Draw(mask)

    for side in (-1, 1):
        x, y = px(0, side * STATION_Y)
        rp = BREAK_R * SS
        mdraw.ellipse([x - rp, y - rp, x + rp, y + rp], fill=0)

    border.putalpha(ImageChops.multiply(border.getchannel("A"), mask))
    img.alpha_composite(border)

    draw = ImageDraw.Draw(img)
    station(img, draw, -STATION_Y)
    station(img, draw, STATION_Y)

    # twin rails from each station to the column fulcrum, broken at the
    # plinth, each pair carrying the menu connector's lozenge
    for side in (-1, 1):
        for off in (-0.9, 0.9):
            seg(draw, (off, side * 5.8), (off, side * (STATION_Y - STATION_R - 0.4)), STROKE_FINE)

        my = side * 12.6
        pts = [(0, my - 1.3), (0.62, my), (0, my + 1.3), (-0.62, my)]

        for k in range(4):
            seg(draw, pts[k], pts[(k + 1) % 4], STROKE_FINE * 0.75)

    img = img.resize(FINAL, Image.LANCZOS)

    out = REPO_ROOT / "materials" / "arcana" / "transmuter_inlay.vtf"

    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / "transmuter_inlay.png"
        img.save(png)
        size, mips = png_to_vtf(png, out)

    print(f"{out} ({size / 1024:.0f} KB, {mips} mips)")


if __name__ == "__main__":
    main()
