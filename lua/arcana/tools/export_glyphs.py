#!/usr/bin/env python3
"""
Arcana Glyph PNG Exporter
Renders each of the 8 Pulsian runic glyphs (A–H) to a square PNG where the
glyph fills a configurable fraction of the canvas (~85 % by default).

Requirements:  pip install Pillow

Output (default): <addon_root>/lua/arcana/tools/glyph_exports/glyph_<charcode>.png

Usage:
    python export_glyphs.py
    python export_glyphs.py --output "C:/path/to/garrysmod/data/arcana/ring_exports"
    python export_glyphs.py --canvas 2048 --fill 0.90
"""

import argparse
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

# ── Configuration ──────────────────────────────────────────────────────────────

GLYPHS      = list("ABCDEFGH")   # characters to export
CANVAS_SIZE = 1024               # output PNG size in pixels (square)
FILL_RATIO  = 0.85               # glyph fills this fraction of the canvas edge

_SCRIPT_DIR = Path(__file__).resolve().parent
# Addon root is 3 levels up from lua/arcana/tools/
_ADDON_ROOT = (_SCRIPT_DIR / "../../..").resolve()
FONT_PATH   = _ADDON_ROOT / "resource" / "fonts" / "pulsian.ttf"

# ── Core rendering ─────────────────────────────────────────────────────────────

def render_glyph(char: str, font_path: Path, canvas: int, fill: float) -> Image.Image:
    """
    Returns a `canvas × canvas` RGBA image with `char` centred and scaled so
    its largest dimension equals `fill * canvas` pixels.
    White glyph on transparent background (ready to tint in-engine).
    """
    # --- Step 1: probe at an arbitrary size to learn the glyph's aspect ratio ---
    PROBE = 400
    probe_font = ImageFont.truetype(str(font_path), PROBE)
    scratch    = Image.new("RGBA", (PROBE * 6, PROBE * 6), (0, 0, 0, 0))
    probe_draw = ImageDraw.Draw(scratch)
    bbox = probe_draw.textbbox((0, 0), char, font=probe_font)

    gw = bbox[2] - bbox[0]
    gh = bbox[3] - bbox[1]
    if gw <= 0 or gh <= 0:
        raise ValueError(
            f"Glyph '{char}' (U+{ord(char):04X}) has zero size in font '{font_path.name}'.\n"
            "Make sure the character exists in the font."
        )

    # --- Step 2: compute the final font size so max(gw, gh) == fill * canvas ---
    scale      = (fill * canvas) / max(gw, gh)
    final_size = max(1, round(PROBE * scale))

    # --- Step 3: render at the computed size ---
    final_font = ImageFont.truetype(str(font_path), final_size)
    img        = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw       = ImageDraw.Draw(img)

    bbox = draw.textbbox((0, 0), char, font=final_font)
    gw   = bbox[2] - bbox[0]
    gh   = bbox[3] - bbox[1]

    # Centre, compensating for the font's internal ascender offset stored in bbox[0]/[1]
    x = (canvas - gw) // 2 - bbox[0]
    y = (canvas - gh) // 2 - bbox[1]

    draw.text((x, y), char, font=final_font, fill=(255, 255, 255, 255))
    return img


# ── CLI ────────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Export Arcana rune glyphs (A–H) to PNG using the Pulsian font."
    )
    parser.add_argument(
        "--output", "-o",
        default=str(_SCRIPT_DIR / "glyph_exports"),
        help="Output directory  (default: %(default)s)"
    )
    parser.add_argument(
        "--font", "-f",
        default=str(FONT_PATH),
        help="Path to pulsian.ttf  (default: %(default)s)"
    )
    parser.add_argument(
        "--canvas", "-s",
        type=int, default=CANVAS_SIZE,
        help=f"Canvas size in pixels  (default: {CANVAS_SIZE})"
    )
    parser.add_argument(
        "--fill", "-r",
        type=float, default=FILL_RATIO,
        help=f"Fraction of canvas the glyph should fill  (default: {FILL_RATIO})"
    )
    parser.add_argument(
        "--glyphs", "-g",
        default="".join(GLYPHS),
        help=f"Characters to export  (default: {''.join(GLYPHS)})"
    )
    args = parser.parse_args()

    font_path  = Path(args.font).resolve()
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    if not font_path.exists():
        print(f"[ERROR] Font not found: {font_path}", file=sys.stderr)
        print("        Pass --font <path> to override.", file=sys.stderr)
        sys.exit(1)

    print(f"Font    : {font_path}")
    print(f"Output  : {output_dir.resolve()}")
    print(f"Canvas  : {args.canvas}×{args.canvas}  fill={args.fill:.0%}")
    print()

    for ch in args.glyphs:
        try:
            img  = render_glyph(ch, font_path, args.canvas, args.fill)
            name = f"glyph_{ord(ch)}.png"
            path = output_dir / name
            img.save(path, "PNG")
            print(f"  {name}  (char '{ch}', U+{ord(ch):04X})")
        except Exception as exc:
            print(f"  [SKIP] '{ch}': {exc}", file=sys.stderr)

    print(f"\nDone — {len(args.glyphs)} file(s) written to {output_dir.resolve()}")


if __name__ == "__main__":
    main()
