#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""How often racing the beam differs from MAME's frame-at-a-time render.

    python scripts/beam_scout.py cshift --coin 300 --frames 1800

MAME draws the whole frame at vblank start from the RAM as it stands then; the
board draws line 100 from the RAM as it stood at line 100. The two disagree
exactly when a write CHANGES a byte and the beam has already passed the pixels
that byte feeds. This counts those per frame, over one emulator run, and says
what fraction of frames a beam-accurate core would render differently from MAME.

The answer decides whether MAME can be the RTL's pixel reference or only the
reference for the rendering function (docs/ROADMAP.md, Phase 1 exit criteria).

WHAT THIS COUNTS, AND WHAT IT DOES NOT. A "late write" here is a write that
changes a BYTE after the beam has passed the pixels that byte feeds. It is an
upper bound on divergence, not a count of wrong pixels, because a changed index
need not be a changed colour: cshift frame 3523 has 1,089 late writes touching
2,202 pixels and renders IDENTICALLY, because every one of those indices maps to
the same RGB in the active palette bank. Use this to find candidate frames, then
render them with `render_model.py` to see what actually differs.
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--skip", type=int, default=600)
    ap.add_argument("--coin", type=int, default=0)
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-beamscout"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    inputs = regions().get("inputs", {})
    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_runner_env("beamscout.lua"),
                   CORE_OUT=out.as_posix(), CORE_FRAMES=str(a.frames),
                   CORE_SKIP=str(a.skip), CORE_COIN=str(a.coin),
                   CORE_IN_COIN=inputs.get("coin", "Coin 1"),
                   CORE_IN_START=inputs.get("start", "1 Player Start"))
        cmd = [str(exe), a.game, "-nodebug", "-nowindow", "-video", "none",
               "-sound", "none", "-skip_gameinfo", "-nothrottle",
               "-autoboot_delay", "0",
               "-autoboot_script", str(LUA_DIR / "run.lua"),
               "-rompath", rompath(mame_dir), "-nvram_directory", nv,
               "-seconds_to_run", str((a.skip + a.frames) // 60 + 15)]
        r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True,
                           text=True, **NO_WINDOW)

    check_lua_error(out)
    tsv = out / "beamdiff.tsv"
    if not tsv.exists():
        sys.stdout.write((r.stdout + r.stderr)[-1500:])
        sys.exit("no beamdiff.tsv written")

    rows = []
    for line in tsv.read_text().splitlines():
        if line.startswith("#"):
            continue
        fr, lv, ls, worst = line.split("\t")
        rows.append((int(fr), int(lv), int(ls), float(worst)))

    state = "play" if a.coin else "attract"
    if not rows:
        print(f"{a.game} ({state}): 0 of {a.frames} frames have a late write. "
              f"A beam-accurate core renders identically to MAME on every frame scanned.")
        return 0
    lv = sum(r[1] for r in rows)
    ls = sum(r[2] for r in rows)
    worst = max(r[3] for r in rows)
    busiest = max(rows, key=lambda r: r[1] + r[2])
    print(f"{a.game} ({state}): {len(rows)} of {a.frames} frames "
          f"({100.0 * len(rows) / a.frames:.1f}%) have at least one late write")
    print("  (an upper bound: a changed index is not always a changed colour)")
    print(f"  video RAM bytes written after their row was drawn : {lv} "
          f"({lv / len(rows):.1f} per affected frame)")
    print(f"  sprite entries written after the sprite was drawn  : {ls} "
          f"({ls / len(rows):.1f} per affected frame)")
    print(f"  worst lateness: {worst:.0f} scanlines")
    print(f"  busiest frame : {busiest[0]} with {busiest[1]} vram + {busiest[2]} sprite")
    return 0


if __name__ == "__main__":
    sys.exit(main())
