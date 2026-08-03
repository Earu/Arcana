#!/usr/bin/env python3
"""Downsample the exported spawnicon captures into the shipped 256x256 PNGs.

The exporter (tools/export_spawnicons.lua) captures the centred square of the game window, so its
output is whatever the game runs at - 1440x1440 at 1440p. Nothing in the frame artwork is
antialiased: it is drawn with surface.DrawRect, which has no AA in Source. Supersampling is what
makes it clean, so the capture is deliberately large and the reduction happens here, where Lanczos
gives a far better result than the engine's bilinear filtering would.

WHY 256 AND NOT 512:
The spawnmenu draws these at 64-128px. PNGs load as mipless BGRA8888 (see tools/png_to_vtf.py for
the measurements), which is 4 bytes/px with no mip chain:

    512x512 BGRA8888  = 1.00 MB each   =  7 MB for the set
    256x256 BGRA8888  = 0.25 MB each   = ~1.8 MB for the set

256 is still 2-4x the size it is ever drawn at.

These stay PNG rather than becoming DXT5 VTFs like the rings did: the spawnmenu looks icons up by
the literal path materials/entities/<class>.png, so the format is not ours to choose.

Full round trip for regenerating an icon:

    1. in-game:  lua_openscript    arcana/tools/export_spawnicons.lua
                 lua_openscript_cl arcana/tools/export_spawnicons.lua
                 arcana_export_spawnicons
                 -> garrysmod/data/arcana/spawnicon_exports/*.png
    2. shell:    python3 tools/build_spawnicons.py \\
                     <gmod>/garrysmod/data/arcana/spawnicon_exports --out materials/entities

Usage:
    python3 tools/build_spawnicons.py SRC [SRC...] [--out DIR] [--size N]
"""

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageFilter
except ImportError:
    sys.exit("Pillow is required: pip install Pillow")

DEFAULT_SIZE = 256

# Light touch. The reduction is 5-6x, which softens the frame's one-pixel brass rule more than the
# subject; a small radius sharpen brings that back without ringing the bloom halos, which are the
# first thing to show artefacts.
UNSHARP_RADIUS = 1.0
UNSHARP_PERCENT = 60
UNSHARP_THRESHOLD = 3


def build(src: Path, out_dir: Path, size: int) -> tuple[bool, str]:
    with Image.open(src) as im:
        im = im.convert("RGB")

        if im.width != im.height:
            return False, f"{src.name}: not square ({im.width}x{im.height}), skipped"

        # A capture taken while the game window was not rendering comes back uniformly black.
        # It is worth catching here rather than shipping an empty tile to the spawnmenu.
        if im.getextrema() == ((0, 0), (0, 0), (0, 0)):
            return False, f"{src.name}: blank capture (all black), skipped"

        icon = im.resize((size, size), Image.LANCZOS)
        icon = icon.filter(
            ImageFilter.UnsharpMask(
                radius=UNSHARP_RADIUS,
                percent=UNSHARP_PERCENT,
                threshold=UNSHARP_THRESHOLD,
            )
        )

        dest = out_dir / src.name
        icon.save(dest, "PNG", optimize=True)

        kb = dest.stat().st_size / 1024
        return True, f"{dest}  {size}x{size}  {kb:.0f} KB"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", nargs="+", type=Path, help="source PNG files, or directories of them")
    ap.add_argument("--out", type=Path, default=Path("materials/entities"), help="output directory")
    ap.add_argument("--size", type=int, default=DEFAULT_SIZE, help=f"output edge in px (default {DEFAULT_SIZE})")
    args = ap.parse_args()

    sources: list[Path] = []
    for s in args.src:
        if s.is_dir():
            sources.extend(sorted(s.glob("*.png")))
        elif s.is_file():
            sources.append(s)
        else:
            print(f"! {s}: not found", file=sys.stderr)

    if not sources:
        print("no source PNGs found", file=sys.stderr)
        return 1

    args.out.mkdir(parents=True, exist_ok=True)

    written, skipped = 0, 0
    for src in sources:
        ok, msg = build(src, args.out, args.size)
        print(("  " if ok else "! ") + msg, file=sys.stdout if ok else sys.stderr)
        written += ok
        skipped += not ok

    print(f"\n{written} icon(s) written to {args.out}" + (f", {skipped} skipped" if skipped else ""))
    return 1 if skipped else 0


if __name__ == "__main__":
    sys.exit(main())
