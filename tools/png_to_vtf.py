#!/usr/bin/env python3
"""Convert the ring/glyph PNGs into mipped DXT5 VTFs.

Loading these through Material("....png") uploads BGRA8888 with no mips, which
is 4 bytes/px - 16 MB for a single 2048x2048 ring. DXT5 is 1 byte/px and keeps
both the greyscale RGB and the 8-bit alpha the art actually uses:

    2048x2048 BGRA8888, no mips  = 16.00 MB   (what the PNG loader produces)
    2048x2048 DXT5 + full mips   =  5.33 MB

Mips are included: the rings are drawn flat on the ground via 3D2D, and without
a mip chain the thin bright lines alias badly at glancing angles. They cost 33%
on top of the base level and that is already priced into the number above.

WHY NOT A8/IA88 - measured, do not retry:
The pixel shader only reads .a, so A8 (1 byte/px) looks like the obvious answer,
and IA88 (2 bytes/px) like the safe one for the 2D paths that need RGB. Both
were built and loaded, and `mat_texture_list` reports what the engine actually
allocated:

    arcana_a8test/a8_ring     21,844 kb  2048x2048  BGRA8
    arcana_a8test/ia88_ring   21,844 kb  2048x2048  BGRA8

The engine expands both to BGRA8888 on load - so they cost MORE than the status
quo once the mip chain is added, not less. Reproduced on a listen server and on
a live server, same result. I8 does survive (see skybox/clouds), but it forces
alpha to 1 and is useless for masks. DXT5 survives at 1 byte/px, so DXT5 it is.

The PNGs are not in the repo - only the VTFs ship, so the source art lives in the
exporter's output folder. Full round trip for changing a ring:

    1. in-game:  include("arcana/tools/export_ring_pngs.lua")
                 -> garrysmod/data/arcana/ring_exports/*.png
    2. shell:    python3 tools/png_to_vtf.py <gmod>/garrysmod/data/arcana/ring_exports \\
                     --out materials/arcana/rings
                 (glyphs land in ring_exports/glyphs -> materials/arcana/glyphs)

Usage:
    python3 tools/png_to_vtf.py SRC [SRC...] [--out DIR]

    SRC   a .png file or a directory of them
    --out where the .vtf files go (default: alongside each source PNG)
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

# Valve texture flags (public/bitmap/imageformat.h)
TEXTUREFLAGS_EIGHTBITALPHA = 0x2000

IMAGE_FORMAT_DXT5 = 15
NO_LOW_RES_IMAGE = -1
HEADER_SIZE = 80   # 7.2 header, padded to a 16-byte boundary
DDS_HEADER_SIZE = 128

REPO_ROOT = Path(__file__).resolve().parent.parent


def build_mip_chain(source: Image.Image):
    """Successive box-filtered halvings, largest first, down to 1x1.

    Box (area average) rather than Lanczos on purpose: these are coverage
    masks, and Lanczos would ring around the strokes and clip at 0/255.
    """
    mips = [source]
    current = source
    while current.size != (1, 1):
        current = current.resize(
            (max(1, current.width // 2), max(1, current.height // 2)),
            Image.BOX,
        )
        mips.append(current)
    return mips


def encode_dxt5(image: Image.Image) -> bytes:
    """One mip level -> raw DXT5 blocks, via ImageMagick's DDS encoder.

    Levels below 4x4 still occupy a full 4x4 block; ImageMagick pads them, so a
    1x1 level correctly comes back as 16 bytes.
    """
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / "level.png"
        dds = Path(tmp) / "level.dds"
        image.save(png)
        subprocess.run(
            [
                "magick", str(png),
                "-define", "dds:compression=dxt5",
                "-define", "dds:mipmaps=0",
                str(dds),
            ],
            check=True,
            capture_output=True,
        )
        return dds.read_bytes()[DDS_HEADER_SIZE:]


def png_to_vtf(png_path: Path, vtf_path: Path) -> tuple[int, int]:
    image = Image.open(png_path).convert("RGBA")
    width, height = image.size
    mips = build_mip_chain(image)

    header = bytearray(HEADER_SIZE)
    struct.pack_into("<4s", header, 0, b"VTF\0")
    struct.pack_into("<II", header, 4, 7, 2)          # version 7.2
    struct.pack_into("<I", header, 12, HEADER_SIZE)
    struct.pack_into("<HH", header, 16, width, height)
    struct.pack_into("<I", header, 20, TEXTUREFLAGS_EIGHTBITALPHA)
    struct.pack_into("<HH", header, 24, 1, 0)         # frames, firstFrame
    struct.pack_into("<fff", header, 32, 1.0, 1.0, 1.0)  # reflectivity
    struct.pack_into("<f", header, 48, 1.0)           # bumpmapScale
    struct.pack_into("<I", header, 52, IMAGE_FORMAT_DXT5)
    struct.pack_into("<B", header, 56, len(mips))
    struct.pack_into("<i", header, 57, NO_LOW_RES_IMAGE)
    struct.pack_into("<BB", header, 61, 0, 0)         # lowRes width/height
    struct.pack_into("<H", header, 63, 1)             # depth

    # VTF stores mip levels smallest-first.
    body = b"".join(encode_dxt5(mip) for mip in reversed(mips))

    vtf_path.write_bytes(bytes(header) + body)
    return len(header) + len(body), len(mips)


def collect(paths):
    for path in paths:
        if path.is_dir():
            yield from sorted(path.glob("*.png"))
        else:
            yield path


def main():
    argv = sys.argv[1:]
    out_dir = None
    if "--out" in argv:
        i = argv.index("--out")
        if i + 1 >= len(argv):
            sys.exit("--out needs a directory")
        out_dir = Path(argv[i + 1])
        del argv[i:i + 2]

    if not argv:
        sys.exit(__doc__.split("Usage:", 1)[1].strip())

    if out_dir is not None:
        out_dir.mkdir(parents=True, exist_ok=True)

    total_before = total_after = 0

    for png in collect([Path(a) for a in argv]):
        vtf = (out_dir / png.name).with_suffix(".vtf") if out_dir else png.with_suffix(".vtf")
        size, mip_count = png_to_vtf(png, vtf)

        with Image.open(png) as probe:
            w, h = probe.size
        vram_before = w * h * 4          # BGRA8888, no mips
        vram_after = size - HEADER_SIZE  # DXT5 blocks, mips included
        total_before += vram_before
        total_after += vram_after

        print(
            f"{png.name:28} {w}x{h:<5} {mip_count:2} mips  "
            f"{size / 1024:8.1f} KB on disk   "
            f"VRAM {vram_before / 1048576:6.2f} -> {vram_after / 1048576:5.2f} MB"
        )

    if total_before:
        print(
            f"\ntotal VRAM {total_before / 1048576:.1f} MB -> "
            f"{total_after / 1048576:.1f} MB "
            f"({100 - total_after / total_before * 100:.0f}% saved)"
        )


if __name__ == "__main__":
    main()
