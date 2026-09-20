#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A state image from MAME: one CPU's registers, its RAM, and the I/O writes
that preceded the image, so a testbench can start where MAME was.

    python scripts/mame_dump_state.py cshift --cpu sound --trig iow:0A:1
    -> debug/<set>-state/<tag>_state.txt      registers and a manifest
       debug/<set>-state/<tag>_ram_2000.hex   $readmemh-ready RAM
       debug/<set>-state/<tag>_iow.txt        every I/O write before the image

Why: sim/calib_tb spends about 50 of its 70 million cycles on the 6VB's RAM
test and ROM checksum, neither of which touches the audio board, before the
self-calibration it exists to test. Starting from an image skips that.

The image is taken at the first machine frame notifier AT OR AFTER the trigger,
not at the trigger itself -- see the header of scripts/mame/dumpstate.lua for
why, and for what a state image cannot carry.
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

# The CPUs worth imaging, and what "RAM" means for each. The 6VB's map is in
# sente6vb.cpp mem_map, the main board's in balsente.cpp cpu1_base_map.
CPUS = {
    "sound": {"tag": ":audio6vb:audiocpu", "ram": "2000:5fff",
              "iospace": "io", "iomask": "ff"},
    "main":  {"tag": ":maincpu", "ram": "0000:8fff",
              "iospace": "", "iomask": "ff"},
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--cpu", choices=sorted(CPUS), default="sound")
    ap.add_argument("--trig", default="iow:0A:1",
                    help="time:<s> | ioany:<n> | iow:<port hex>:<n>")
    ap.add_argument("--tag", default=None, help="filename prefix (default: the set name)")
    ap.add_argument("--ram", default=None, help="override the RAM ranges, 'lo:hi,lo:hi' hex")
    ap.add_argument("--seconds", type=float, default=30.0,
                    help="give up after this much emulated time")
    a = ap.parse_args()

    c = CPUS[a.cpu]
    tag = a.tag or a.game
    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-state"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_runner_env("dumpstate.lua"),
                   CORE_OUT=out.as_posix(), CORE_TAG=tag,
                   CORE_CPU=c["tag"], CORE_SPACE=regions()["space"],
                   CORE_RAM=a.ram or c["ram"],
                   CORE_IOSPACE=c["iospace"], CORE_IOMASK=c["iomask"],
                   CORE_TRIG=a.trig)
        cmd = [str(exe), a.game, "-nodebug", "-nowindow", "-video", "none",
               "-skip_gameinfo", "-nothrottle", "-autoboot_delay", "0",
               "-autoboot_script", str(LUA_DIR / "run.lua"),
               "-rompath", rompath(mame_dir),
               "-nvram_directory", nv,
               "-sound", "none",
               "-seconds_to_run", str(int(a.seconds))]
        r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True,
                           **NO_WINDOW)

    check_lua_error(out)
    man = out / f"{tag}_state.txt"
    if not man.exists():
        sys.stdout.write(r.stdout[-2000:])
        sys.stderr.write(r.stderr[-2000:])
        sys.exit(f"no image written -- the trigger {a.trig!r} never fired within "
                 f"{a.seconds}s of emulated time")
    text = man.read_text()
    if "\nreg\t" not in text:
        sys.exit(f"{man} has no registers -- the CPU's state entries were not read")
    for line in text.splitlines():
        if line.startswith(("time_s", "io_seq", "iow", "ram")):
            print(line)
    print(f"{sum(1 for ln in text.splitlines() if ln.startswith('reg'))} registers")
    print(f"-> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
