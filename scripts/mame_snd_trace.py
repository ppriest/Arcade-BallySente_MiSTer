#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The 6VB's CEM3394 control writes and MAME's own audio, from one run.

    python scripts/mame_snd_trace.py cshift 12
    -> debug/<set>-snd/<set>_snd.trace   the control writes, timestamped
       debug/<set>-snd/<set>.wav         what MAME's model produced from them

The pair scripts/cem3394_replay.py needs: drive the software model with the same
writes and compare against the same recording.

`-samplerate 96000` matters. MAME runs `va_vco` at the machine sample rate and
`va_lpf4` at max(96 kHz, that rate), resampling between them; at 96 kHz the two
run at the same rate and MAME's internal resampler drops out of the comparison.
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
                          lua_runner_env, mame_paths, rompath)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("seconds", type=float, nargs="?", default=10.0,
                    help="emulated seconds to record")
    ap.add_argument("--rate", type=int, default=96000)
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-snd"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    wav = out / f"{a.game}.wav"

    with tempfile.TemporaryDirectory() as nv:
        env = dict(os.environ, **lua_runner_env("sndtrace.lua"),
                   CORE_OUT=out.as_posix(), CORE_TAG=a.game,
                   CORE_SECONDS=str(a.seconds))
        cmd = [str(exe), a.game, "-nodebug", "-nowindow", "-video", "none",
               "-skip_gameinfo", "-nothrottle", "-autoboot_delay", "0",
               "-autoboot_script", str(LUA_DIR / "run.lua"),
               "-rompath", rompath(mame_dir),
               "-nvram_directory", nv,
               "-samplerate", str(a.rate),
               "-sound", "none", "-wavwrite", str(wav),
               "-seconds_to_run", str(int(a.seconds) + 5)]
        r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True,
                           **NO_WINDOW)

    check_lua_error(out)
    trace = out / f"{a.game}_snd.trace"
    if not trace.exists():
        sys.stdout.write(r.stdout[-2000:])
        sys.stderr.write(r.stderr[-2000:])
        sys.exit("no trace written; see MAME output above")
    lines = trace.read_text().splitlines()
    print("\n".join(lines[-1:]))
    if any(ln.startswith("# FIRST ERROR") for ln in lines):
        sys.exit("the trace recorded a tap error; see the file")
    if not wav.exists() or wav.stat().st_size <= 44:
        sys.exit(f"no audio written to {wav} -- MAME's sound output was not producing "
                 "samples; try a different -sound module")
    print(f"{wav.stat().st_size} bytes of audio -> {wav}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
