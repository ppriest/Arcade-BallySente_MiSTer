#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Find the frames worth capturing, one MAME run per game.

    python scripts/sprite_scout.py cshift --coin 300 --frames 5400
    -> debug/<set>-scout/sprites.tsv, and a shortlist on stdout

A capture is only evidence for the paths it runs. Most frames of most
Bally/Sente games run very few: attract mode points all 40 sprite entries at
image 0, which is blank, so the sprite path executes and draws nothing. This
walks the sprite list every frame and reports what each frame would exercise,
then names the frames that cover flip X, flip Y and the screen edges.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import (LUA_DIR, NO_WINDOW, check_lua_error,  # noqa: E402
                          lua_runner_env, mame_paths, regions, rompath)


def shortlist(rows):
    """One frame per interesting property, preferring the busiest."""
    want = {
        "flip X": lambda r: r["flags"] & 0x40,
        "flip Y": lambda r: r["flags"] & 0x80,
        "both flips": lambda r: (r["flags"] & 0xc0) == 0xc0,
        "near the right edge (x >= 249)": lambda r: r["maxx"] >= 249,
        "near the left edge (x <= 4)": lambda r: r["minx"] <= 4,
        "wrapping off the bottom (y >= 224)": lambda r: r["maxy"] >= 224,
        "busiest": lambda r: True,
    }
    out = []
    for label, pred in want.items():
        hits = [r for r in rows if pred(r)]
        if not hits:
            out.append((label, None))
            continue
        best = max(hits, key=lambda r: (r["live"], r["images"]))
        out.append((label, best))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--frames", type=int, default=5400, help="frames to scan")
    ap.add_argument("--coin", type=int, default=300,
                    help="frame at which to insert a coin; 0 for attract only")
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-scout"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    inputs = regions().get("inputs", {})
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_runner_env("spritescout.lua"),
                   CORE_OUT=out.as_posix(), CORE_FRAMES=str(a.frames),
                   CORE_COIN=str(a.coin),
                   CORE_IN_COIN=inputs.get("coin", "Coin 1"),
                   CORE_IN_START=inputs.get("start", "1 Player Start"))
        cmd = [str(exe), a.game, "-nodebug", "-nowindow", "-video", "none",
               "-sound", "none", "-skip_gameinfo", "-nothrottle",
               "-autoboot_delay", "0",
               "-autoboot_script", str(LUA_DIR / "run.lua"),
               "-rompath", rompath(mame_dir), "-nvram_directory", nv,
               "-seconds_to_run", str(a.frames // 60 + 15)]
        r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True,
                           text=True, **NO_WINDOW)

    check_lua_error(out)
    tsv = out / "sprites.tsv"
    if not tsv.exists():
        sys.stdout.write((r.stdout + r.stderr)[-1500:])
        sys.exit("no sprites.tsv written")

    rows = []
    for line in tsv.read_text().splitlines():
        if line.startswith("#"):
            continue
        f, live, flags, images, minx, maxx, miny, maxy = line.split("\t")
        rows.append(dict(frame=int(f), live=int(live), flags=int(flags, 16),
                         images=int(images), minx=int(minx), maxx=int(maxx),
                         miny=int(miny), maxy=int(maxy)))
    if not rows:
        print(f"{a.game}: no frame in {a.frames} had a live sprite. "
              f"Try a later --coin or more --frames.")
        return 1

    print(f"{a.game}: {len(rows)} of {a.frames} frames have live sprites; "
          f"flags seen {sorted({r['flags'] & 0xc0 for r in rows})}")
    for label, r in shortlist(rows):
        if r is None:
            print(f"  {label:34s} none")
        else:
            print(f"  {label:34s} frame {r['frame']:5d}  live {r['live']:2d} "
                  f"images {r['images']:2d} flags {r['flags']:02X} "
                  f"x {r['minx']}-{r['maxx']} y {r['miny']}-{r['maxy']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
