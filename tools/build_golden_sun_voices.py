#!/usr/bin/env python3
import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCENE_LUA = ROOT / "lua/arcana/scenes/golden_sun.lua"
SOUND_DIR = ROOT / "sound"
LAUGH_DIR = "arcana/scenes/golden_sun"

NODE_RE = re.compile(r'text\s*=\s*"((?:[^"\\]|\\.)*)",\s*voice\s*=\s*"([^"]+)"')

LAUGHS = {
    "laugh_1": "[[rate 160]] [[pbas 58]] heh [[slnc 60]] [[pbas 54]] heh [[slnc 60]] [[pbas 50]] hah [[slnc 50]] "
               "[[pbas 45]] hah [[slnc 50]] [[pbas 40]] hah [[slnc 80]] [[pbas 34]] haaah",
    "laugh_2": "[[rate 140]] [[pbas 40]] hm [[slnc 120]] hm [[slnc 100]] [[pbas 44]] hah hah [[pbas 38]] hah "
               "[[slnc 150]] [[pbas 30]] haaaa",
    "laugh_3": "[[rate 190]] [[pbas 62]] ha ha ha ha [[pbas 55]] ha ha ha [[pbas 46]] ha ha [[slnc 100]] "
               "[[pbas 36]] haaaaah",
    "laugh_4": "[[rate 110]] [[pbas 50]] hoh [[slnc 200]] [[pbas 46]] hoh [[slnc 180]] [[pbas 40]] hoh "
               "[[slnc 160]] [[pbas 33]] hooooh",
}

FILTER = """
[0:a]aresample=44100{reverse_all},asplit=3[a][b][c];
[a]asetrate=44100*0.55,aresample=44100,atempo=1.4909,vibrato=f=3.2:d=0.25[main];
[b]asetrate=44100*0.30,aresample=44100,atempo=1.6,atempo=1.7083,lowpass=f=700,volume=1.6[sub];
[c]{reverse_ghost}asetrate=44100*0.82,aresample=44100,flanger=delay=8:depth=6:speed=0.3,highpass=f=900,volume={ghost}[ghost];
[main][sub][ghost]amix=inputs=3:normalize=0,
lowpass=f=3200,
apad=pad_dur={tail},
aecho=0.8:0.8:110|240|470|820:0.4|0.28|0.18|0.1,
aphaser=type=t:speed=0.25:decay=0.5,
loudnorm=I=-15:TP=-1.5:LRA=11,
aresample=44100
"""

SPEECH = FILTER.format(reverse_all=",areverse", reverse_ghost="", ghost=0.18, tail=2.5)
LAUGH = FILTER.format(reverse_all="", reverse_ghost="areverse,", ghost=0.3, tail=3.5)


def pick_encoder():
    if shutil.which("oggenc"):
        return "oggenc"
    encoders = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True).stdout
    if " libvorbis " in encoders:
        return "libvorbis"
    print("warning: no oggenc or libvorbis, writing stereo (Source won't spatialise the laughs). "
          "Fix: brew install vorbis-tools", file=sys.stderr)
    return "native"


def ffmpeg(src, filt, out_args):
    subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(src), "-filter_complex", filt, *out_args],
        check=True,
    )


def render(text, out, voice, rate, filt, encoder):
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        raw = Path(tmp) / "raw.aiff"
        subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", str(raw), text], check=True)
        if encoder == "oggenc":
            wav = Path(tmp) / "out.wav"
            ffmpeg(raw, filt, ["-ac", "1", str(wav)])
            subprocess.run(["oggenc", "-Q", "-q", "4", "-o", str(out), str(wav)], check=True)
        elif encoder == "libvorbis":
            ffmpeg(raw, filt, ["-ac", "1", "-c:a", "libvorbis", "-q:a", "4", str(out)])
        else:
            ffmpeg(raw, filt, ["-ac", "2", "-c:a", "vorbis", "-strict", "experimental", "-b:a", "112k", str(out)])


def main():
    parser = argparse.ArgumentParser(description="Render the Golden Sun voice lines and laughs.")
    parser.add_argument("names", nargs="*", help="Only render these files (e.g. start laugh_2). Default: all.")
    parser.add_argument("--voice", default="Ralph", help="macOS say voice (default: Ralph)")
    parser.add_argument("--rate", type=int, default=135, help="say words per minute (default: 135)")
    args = parser.parse_args()

    for tool in ("say", "ffmpeg"):
        if not shutil.which(tool):
            sys.exit(f"missing dependency: {tool}")

    jobs = [(text.replace('\\"', '"'), path, SPEECH) for text, path in NODE_RE.findall(SCENE_LUA.read_text())]
    jobs += [(text, f"{LAUGH_DIR}/{name}.ogg", LAUGH) for name, text in LAUGHS.items()]
    if args.names:
        jobs = [j for j in jobs if Path(j[1]).stem in args.names]
    if not jobs:
        sys.exit("no matching files")

    encoder = pick_encoder()
    for text, path, filt in jobs:
        out = SOUND_DIR / path
        render(text, out, args.voice, args.rate, filt, encoder)
        print(out.relative_to(ROOT))


if __name__ == "__main__":
    main()
