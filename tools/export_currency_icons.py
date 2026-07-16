#!/usr/bin/env python3
"""
Arcana Currency Icon Exporter
Renders the flat coin and crystal shard icons drawn next to costs in the UI.
Both are white silhouettes on transparency, tinted in-engine with the
currency's color (ArtDeco.Colors.coinGold / shardBlue), so disabled states
can dim them through the tint alone.

Requirements:  pip install Pillow

Output (default): <addon_root>/materials/arcana/icons/{coin,crystal_shard}.png

Usage:
    python export_currency_icons.py
    python export_currency_icons.py --size 32
"""

import argparse
import math
from pathlib import Path
from PIL import Image, ImageDraw

# ── Configuration ──────────────────────────────────────────────────────────────

SUPERSAMPLE = 256   # render size before downscale
OUT_SIZE    = 64    # shipped icon size
TILT_DEG    = 15    # clockwise shard tilt so it reads as a loose gem

_SCRIPT_DIR = Path(__file__).resolve().parent
_ADDON_ROOT = _SCRIPT_DIR.parent
OUT_DIR     = _ADDON_ROOT / "materials" / "arcana" / "icons"

# Shard silhouette in unit space (x: -0.62..0.62, y: -1..1), tip up, point down.
# Kept wide so it doesn't look undersized next to the near-full-canvas coin.
SHARD_OUTLINE = [
    (0.00, -1.00),   # top tip
    (0.62, -0.40),   # upper right shoulder
    (0.48, 0.55),    # lower right
    (0.00, 1.00),    # bottom point
    (-0.48, 0.55),   # lower left
    (-0.62, -0.40),  # upper left shoulder
]

# Facet ridge from tip to bottom point, offset so the two facets are uneven.
SHARD_RIDGE = [(0.00, -1.00), (-0.08, -0.20), (0.00, 1.00)]


def _shard_points(points, canvas, tilt_deg):
    """Unit-space -> pixel-space with tilt, uniform scale and centering."""
    a = math.radians(tilt_deg)
    ca, sa = math.cos(a), math.sin(a)
    scale = canvas * 0.48  # shard is 2 units tall; headroom for the tilt
    cx = cy = canvas / 2
    out = []
    for x, y in points:
        rx = x * ca - y * sa
        ry = x * sa + y * ca
        out.append((cx + rx * scale, cy + ry * scale))
    return out


def _from_mask(mask: Image.Image) -> Image.Image:
    """White RGB with the given alpha mask."""
    img = Image.new("RGBA", mask.size, (255, 255, 255, 255))
    img.putalpha(mask)
    return img


def render_shard(canvas: int, tilt_deg: float) -> Image.Image:
    mask = Image.new("L", (canvas, canvas), 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon(_shard_points(SHARD_OUTLINE, canvas, tilt_deg), fill=255)
    # Relief instead of a seam: the left facet at lower alpha renders as a
    # darker shade of whatever color the icon is tinted with.
    tip, ur, lr, bot, ll, ul = _shard_points(SHARD_OUTLINE, canvas, tilt_deg)
    _, rmid, _ = _shard_points(SHARD_RIDGE, canvas, tilt_deg)
    draw.polygon([tip, rmid, bot, ll, ul], fill=175)
    return _from_mask(mask)


def _circle(draw, cx, cy, r, **kw):
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], **kw)


def render_coin(canvas: int) -> Image.Image:
    """Two overlapping coins, front one separated by a transparent seam halo."""
    mask = Image.new("L", (canvas, canvas), 0)
    draw = ImageDraw.Draw(mask)
    seam = canvas // 16
    rim = canvas // 24

    # Back coin, up-left: solid — at chip size any inner detail on it merges
    # with the front coin's rim into a cross-like glyph.
    _circle(draw, canvas * 0.36, canvas * 0.36, canvas * 0.30, fill=255)

    # Front coin, down-right, rim ring kept close to the edge so the face
    # stays a big solid disc.
    fx, fy, fr = canvas * 0.62, canvas * 0.62, canvas * 0.34
    _circle(draw, fx, fy, fr + seam, fill=0)
    _circle(draw, fx, fy, fr, fill=255)
    _circle(draw, fx, fy, fr * 0.74, outline=0, width=rim)
    return _from_mask(mask)


def main() -> None:
    parser = argparse.ArgumentParser(description="Export the Arcana flat currency icons.")
    parser.add_argument("--output", "-o", default=str(OUT_DIR), help="Output directory  (default: %(default)s)")
    parser.add_argument("--size", "-s", type=int, default=OUT_SIZE, help=f"Final icon size  (default: {OUT_SIZE})")
    parser.add_argument("--tilt", "-t", type=float, default=TILT_DEG, help=f"Shard tilt in degrees  (default: {TILT_DEG})")
    args = parser.parse_args()

    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    for name, img in (("coin", render_coin(SUPERSAMPLE)), ("crystal_shard", render_shard(SUPERSAMPLE, args.tilt))):
        path = out_dir / f"{name}.png"
        img.resize((args.size, args.size), Image.LANCZOS).save(path, "PNG")
        print(f"Wrote {path} ({args.size}x{args.size})")


if __name__ == "__main__":
    main()
