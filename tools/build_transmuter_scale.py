#!/usr/bin/env python3
"""Build the transmuter balance scale as real models.

The scale used to be unlit IMesh geometry with baked facet shading; as .mdl
props it gets engine lighting, smooth cylinder normals and painted materials.
Three pieces keep the articulation the entity already has: the column is
static, the beam tilts around its pivot, and the pan (spawned twice) hangs
plumb from each beam end.

Two materials: "brass" is a 512 atlas (plain aged brass on the left half, a
graduation-tick strip for the beam, a lathe-groove strip for the plinth and
capital), and "rope" is a small tiling twisted-cord texture for the pan
hangers, which are round cords rather than gold rods.

Origins: column at the slab-top centre, beam at its pivot, pan at its hook.
Dimensions mirror lua/entities/arcana_transmuter.lua.

Requires wine and GMod's studiomdl. Compiled files land in the game's models/
directory and are copied back into the repo.

Usage:
    python3 tools/build_transmuter_scale.py [--gmod /path/to/GarrysMod]
    -> models/arcana/transmuter/scale_{column,beam,pan}.*
    -> materials/models/arcana/transmuter/{brass,rope}.{vmt,vtf}, brass_normal.vtf
"""

import argparse
import math
import random
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

from png_to_vtf import png_to_vtf

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_GMOD = Path("/mnt/games/SteamLibrary/steamapps/common/GarrysMod")

BRASS = "brass"
ROPE = "rope"

# brass atlas regions (u ranges; v is free)
PLAIN_U = (0.03, 0.47)
TICKS_U = (0.53, 0.73)
GROOVE_U = (0.77, 0.97)
TICK_COUNT = 26


class Smd:
    """Triangle accumulator with a material per triangle; quads arrive
    counter-clockwise seen from outside (the same convention as the entity's
    IMesh code).

    Two studiomdl conventions, both established empirically against GMod's
    compiler: triangles are stored in that CCW order directly (studiomdl does
    the clockwise flip the engine wants; pre-flipping renders inside-out), and
    reference geometry is yawed 90 degrees on compile, so the writer rotates
    everything by the inverse."""

    def __init__(self):
        self.tris = []

    def tri(self, mat, v1, v2, v3):
        self.tris.append((mat, v1, v2, v3))

    def quad(self, mat, v1, v2, v3, v4):
        self.tri(mat, v1, v2, v3)
        self.tri(mat, v1, v3, v4)

    def write(self, path):
        def rot(v):
            return (-v[1], v[0], v[2])

        with open(path, "w") as f:
            f.write("version 1\nnodes\n0 \"root\" -1\nend\nskeleton\ntime 0\n0 0 0 0 0 0 0\nend\ntriangles\n")

            for (mat, *verts) in self.tris:
                f.write(mat + "\n")

                for (p, n, uv) in verts:
                    p, n = rot(p), rot(n)
                    f.write("0 %.4f %.4f %.4f %.4f %.4f %.4f %.4f %.4f\n"
                            % (p[0], p[1], p[2], n[0], n[1], n[2], uv[0], uv[1]))

            f.write("end\n")


def norm(v):
    l = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])

    return (v[0] / l, v[1] / l, v[2] / l) if l > 1e-9 else (0, 0, 1)


def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def mul(a, s):
    return (a[0] * s, a[1] * s, a[2] * s)


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def cylinder(smd, base, r0, h, segs, r1=None, inward=False, uspan=PLAIN_U, vspan=None):
    """Z-aligned side wall with smooth radial normals; taper tilts them.
    uspan maps the full turn into an atlas column (the seam stretch is
    invisible on metal); vspan=(v0, v1) maps the height, else height tiles."""
    r1 = r0 if r1 is None else r1
    slant = (r0 - r1) / max(h, 1e-6)

    for i in range(segs):
        a0 = i / segs * math.tau
        a1 = (i + 1) / segs * math.tau
        verts = []

        for (a, r, z) in ((a0, r0, 0), (a1, r0, 0), (a1, r1, h), (a0, r1, h)):
            c, s = math.cos(a), math.sin(a)
            p = (base[0] + c * r, base[1] + s * r, base[2] + z)
            n = norm((c, s, slant))

            if inward:
                n = mul(n, -1)

            u = uspan[0] + (a / math.tau) * (uspan[1] - uspan[0])
            v = (vspan[0] + (z / h) * (vspan[1] - vspan[0])) if vspan else z * 0.06

            verts.append((p, n, (u, v)))

        if inward:
            smd.quad(BRASS, verts[1], verts[0], verts[3], verts[2])
        else:
            smd.quad(BRASS, *verts)


def disc(smd, center, r, segs, down=False, r_inner=0.0):
    n = (0, 0, -1) if down else (0, 0, 1)

    for i in range(segs):
        a0 = i / segs * math.tau
        a1 = (i + 1) / segs * math.tau
        pts = []

        for (a, rr) in ((a0, r), (a1, r), (a1, r_inner), (a0, r_inner)):
            c, s = math.cos(a), math.sin(a)
            p = (center[0] + c * rr, center[1] + s * rr, center[2])
            pts.append((p, n, (0.25 + p[0] * 0.015, 0.5 + p[1] * 0.015)))

        o1, o2, i2, i1 = pts

        if down:
            smd.quad(BRASS, o2, o1, i1, i2)
        else:
            smd.quad(BRASS, o1, o2, i2, i1)


def box_frame(smd, c, ax, ay, az, uvbox=None):
    """Faceted box from a right-handed half-axis frame. uvbox=(u0,v0,u1,v1)
    stretches every face over that atlas region; default is a small planar
    mapping into the plain field."""

    def face(e1, e2, e3):
        n = norm(cross(e1, e2))
        corners = [
            add(add(sub(c, e1), mul(e2, -1)), e3),
            add(add(add(c, e1), mul(e2, -1)), e3),
            add(add(add(c, e1), e2), e3),
            add(add(sub(c, e1), e2), e3),
        ]

        if uvbox:
            u0, v0, u1, v1 = uvbox
            uvs = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
        else:
            lu = min(0.4, 0.08 * math.sqrt(sum(x * x for x in e1)))
            lv = min(0.9, 0.08 * math.sqrt(sum(x * x for x in e2)))
            uvs = [(0.1, 0.1), (0.1 + lu, 0.1), (0.1 + lu, 0.1 + lv), (0.1, 0.1 + lv)]

        smd.quad(BRASS, *[(p, n, uv) for p, uv in zip(corners, uvs)])

    face(ax, ay, az)
    face(mul(ax, -1), ay, mul(az, -1))
    face(ay, az, ax)
    face(mul(ay, -1), az, mul(ax, -1))
    face(az, ax, ay)
    face(mul(az, -1), ax, mul(ay, -1))


def box(smd, center, hx, hy, hz):
    box_frame(smd, center, (hx, 0, 0), (0, hy, 0), (0, 0, hz))


def rod(smd, a, b, w):
    d = sub(b, a)
    l = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)

    if l < 0.01:
        return

    d = mul(d, 1 / l)
    up = (1, 0, 0) if abs(d[2]) > 0.95 else (0, 0, 1)
    right = norm(cross(d, up))
    box_frame(smd, mul(add(a, b), 0.5), mul(cross(right, d), w), mul(right, w), mul(d, l * 0.5))


def cord(smd, a, b, r, segs=6):
    """Round cord between two points, rope material, twist tiling along it."""
    d = sub(b, a)
    l = math.sqrt(d[0] ** 2 + d[1] ** 2 + d[2] ** 2)

    if l < 0.01:
        return

    d = mul(d, 1 / l)
    up = (1, 0, 0) if abs(d[2]) > 0.95 else (0, 0, 1)
    e1 = norm(cross(d, up))
    e2 = cross(d, e1)
    vtile = l * 0.55

    for i in range(segs):
        a0 = i / segs * math.tau
        a1 = (i + 1) / segs * math.tau
        verts = []

        for (ang, t) in ((a0, 0), (a1, 0), (a1, 1), (a0, 1)):
            c, s = math.cos(ang), math.sin(ang)
            radial = add(mul(e1, c), mul(e2, s))
            p = add(add(a, mul(d, l * t)), mul(radial, r))
            verts.append((p, radial, (ang / math.tau, t * vtile)))

        smd.quad(ROPE, *verts)


# dimensions from the entity, relative to each piece's origin
BEAM_HALF = 26
PAN_HANG = 9


def build_column():
    smd = Smd()
    # plinth and capital carry the lathe grooves, the shaft stays plain
    cylinder(smd, (0, 0, 0), 4.2, 1.4, 20, 3.6, uspan=GROOVE_U, vspan=(0.05, 0.95))
    disc(smd, (0, 0, 1.4), 3.6, 20, r_inner=1.9)
    cylinder(smd, (0, 0, 1.4), 1.9, 2.2, 16, 1.3, uspan=GROOVE_U, vspan=(0.1, 0.9))
    cylinder(smd, (0, 0, 3.6), 1.3, 18.6, 16, 1.0)
    cylinder(smd, (0, 0, 22.2), 1.6, 1.0, 16, uspan=GROOVE_U, vspan=(0.2, 0.8))
    disc(smd, (0, 0, 22.2), 1.6, 16, down=True, r_inner=1.0)
    disc(smd, (0, 0, 23.2), 1.6, 16)
    box(smd, (0, 0, 24.3), 1.1, 1.1, 1.1)
    cylinder(smd, (0, 0, 25.4), 0.7, 1.6, 12, 0.08)
    disc(smd, (0, 0, 27.0), 0.08, 12)

    return smd


def build_beam():
    smd = Smd()
    # the bar takes the graduation strip, everything else stays plain
    box_frame(smd, (0, 0, 0), (0.7, 0, 0), (0, BEAM_HALF, 0), (0, 0, 0.85),
              uvbox=(TICKS_U[0], 0.0, TICKS_U[1], 1.0))
    box(smd, (0, 0, 0), 0.95, 2.2, 1.15)
    box(smd, (0, -BEAM_HALF, 0), 0.95, 0.55, 1.5)
    box(smd, (0, BEAM_HALF, 0), 0.95, 0.55, 1.5)
    rod(smd, (0, 0, -0.6), (0, 0, -4.4), 0.14)

    return smd


def build_pan():
    smd = Smd()

    # hangers are cords, not metal rods
    for k in range(3):
        a = k * math.tau / 3 + math.pi / 6
        cord(smd, (0, 0, 0), (math.cos(a) * 5.2, math.sin(a) * 5.2, -PAN_HANG + 0.8), 0.2)

    cylinder(smd, (0, 0, -PAN_HANG), 6, 1.0, 20)
    disc(smd, (0, 0, -PAN_HANG + 1.0), 6, 20, r_inner=4.4)
    disc(smd, (0, 0, -PAN_HANG + 0.35), 4.4, 20)
    cylinder(smd, (0, 0, -PAN_HANG + 0.35), 4.4, 0.65, 20, inward=True)
    disc(smd, (0, 0, -PAN_HANG), 6, 20, down=True)

    return smd


def value_grid(rng, cells, size, amp):
    """Low-frequency value noise: random grid, bilinear upsample."""
    grid = [[rng.uniform(-amp, amp) for _ in range(cells + 1)] for _ in range(cells + 1)]
    out = [[0.0] * size for _ in range(size)]

    for y in range(size):
        gy = y / size * cells
        y0 = int(gy)
        fy = gy - y0

        for x in range(size):
            gx = x / size * cells
            x0 = int(gx)
            fx = gx - x0
            a = grid[y0][x0] * (1 - fx) + grid[y0][x0 + 1] * fx
            b = grid[y0 + 1][x0] * (1 - fx) + grid[y0 + 1][x0 + 1] * fx
            out[y][x] = a * (1 - fy) + b * fy

    return out


def build_textures(matdir):
    matdir.mkdir(parents=True, exist_ok=True)
    rng = random.Random(7)

    # brass atlas: aged mottling everywhere, then the beam and groove strips.
    # Metal reads through specular; high-contrast albedo detail reads as wood
    # grain at this texel density (tried, rejected).
    S = 512
    img = Image.new("RGB", (S, S))
    px = img.load()
    blotch = value_grid(rng, 12, S, 7)

    for y in range(S):
        for x in range(S):
            g = blotch[y][x] + rng.uniform(-2, 2)
            px[x, y] = (round(150 + g), round(114 + g * 0.8), round(60 + g * 0.5))

    def darken(x, y, amount):
        if 0 <= x < S and 0 <= y < S:
            r, g, b = px[x, y]
            px[x, y] = (max(0, r - amount), max(0, g - round(amount * 0.85)), max(0, b - round(amount * 0.6)))

    # graduation ticks across the beam strip, bolder marks at ends and centre
    tx0, tx1 = round(TICKS_U[0] * S) - 6, round(TICKS_U[1] * S) + 6

    for i in range(TICK_COUNT + 1):
        yy = round(i / TICK_COUNT * (S - 1))
        long_tick = i % 13 == 0
        inset = 0 if long_tick else 24

        for x in range(tx0 + inset, tx1 - inset):
            for dy in (0, 1):
                darken(x, yy + dy, 46)

    # lathe grooves across the plinth strip, shaded darker toward the foot
    gx0, gx1 = round(GROOVE_U[0] * S) - 6, round(GROOVE_U[1] * S) + 6

    for gv in (0.22, 0.5, 0.78):
        yy = round(gv * S)

        for x in range(gx0, gx1):
            for dy in (-1, 0, 1):
                darken(x, yy + dy, 30 if dy == 0 else 14)

    for y in range(S):
        shade = round(max(0.0, y / S - 0.75) * 60)

        if shade > 0:
            for x in range(gx0, gx1):
                darken(x, y, shade)

    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp) / "brass.png"
        img.convert("RGBA").save(p)
        png_to_vtf(p, matdir / "brass.vtf")

        # twisted cord: diagonal strand shading plus fibre noise, tiling
        RS = 64
        rope = Image.new("RGB", (RS, RS))
        rpx = rope.load()

        for y in range(RS):
            for x in range(RS):
                t = ((x + y * 2) % RS) / RS
                strand = 0.72 + 0.28 * math.sin(t * math.tau) ** 2
                f = strand + rng.uniform(-0.05, 0.05)
                rpx[x, y] = (round(138 * f), round(112 * f), round(78 * f))

        p2 = Path(tmp) / "rope.png"
        rope.convert("RGBA").save(p2)
        png_to_vtf(p2, matdir / "rope.vtf")

        flat = Image.new("RGBA", (32, 32), (128, 128, 255, 255))
        p3 = Path(tmp) / "brass_normal.png"
        flat.save(p3)
        png_to_vtf(p3, matdir / "brass_normal.vtf")

    (matdir / "brass.vmt").write_text(
        '"VertexlitGeneric"\n'
        "{\n"
        '\t"$basetexture" "models/arcana/transmuter/brass"\n'
        '\t"$bumpmap" "models/arcana/transmuter/brass_normal"\n'
        '\t"$model" "1"\n'
        '\t"$nodecal" "1"\n'
        '\t"$phong" "1"\n'
        '\t"$phongboost" "3"\n'
        '\t"$phongalbedotint" "1"\n'
        '\t"$phongexponent" "60"\n'
        '\t"$phongfresnelranges" "[0.1 0.7 1]"\n'
        '\t"$envmap" "env_cubemap"\n'
        '\t"$envmaptint" "[0.18 0.15 0.10]"\n'
        '\t"$normalmapalphaenvmapmask" "1"\n'
        '\t"$rimlight" "1"\n'
        '\t"$rimlightexponent" "4"\n'
        '\t"$rimlightboost" "0.6"\n'
        "}\n"
    )

    (matdir / "rope.vmt").write_text(
        '"VertexlitGeneric"\n'
        "{\n"
        '\t"$basetexture" "models/arcana/transmuter/rope"\n'
        '\t"$model" "1"\n'
        '\t"$nodecal" "1"\n'
        '\t"$halflambert" "1"\n'
        "}\n"
    )


QC = """$modelname "arcana/transmuter/{name}.mdl"
$cdmaterials "models/arcana/transmuter"
$surfaceprop "metal"
$body "body" "{name}"
$sequence "idle" "{name}" fps 1
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gmod", type=Path, default=DEFAULT_GMOD)
    args = ap.parse_args()

    gamedir = args.gmod / "garrysmod"
    studiomdl = args.gmod / "bin" / "studiomdl.exe"

    if not studiomdl.exists():
        raise SystemExit(f"studiomdl not found: {studiomdl}")

    build_textures(REPO_ROOT / "materials" / "models" / "arcana" / "transmuter")

    pieces = {
        "scale_column": build_column(),
        "scale_beam": build_beam(),
        "scale_pan": build_pan(),
    }

    outdir = REPO_ROOT / "models" / "arcana" / "transmuter"
    outdir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        for name, smd in pieces.items():
            smd.write(tmp / f"{name}.smd")
            (tmp / f"{name}.qc").write_text(QC.format(name=name))

            r = subprocess.run(
                ["wine", str(studiomdl), "-game", f"Z:{gamedir}", "-nop4", "-verbose", f"{name}.qc"],
                cwd=tmp, capture_output=True, text=True,
            )

            if r.returncode != 0:
                print(r.stdout[-3000:])
                print(r.stderr[-2000:])
                raise SystemExit(f"studiomdl failed on {name}")

            for ext in (".mdl", ".vvd", ".dx80.vtx", ".dx90.vtx"):
                src = gamedir / "models" / "arcana" / "transmuter" / f"{name}{ext}"

                if not src.exists():
                    raise SystemExit(f"expected output missing: {src}")

                shutil.copy2(src, outdir / f"{name}{ext}")

            print(f"{name}: {len(pieces[name].tris)} tris compiled")


if __name__ == "__main__":
    main()
