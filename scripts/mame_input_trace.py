#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reads of an input register under a fixed input schedule, from MAME and from
sim/board_tb, compared.

    python scripts/mame_input_trace.py grudge 900             # MAME side
    scripts/run_verilator.sh board_tb +image=... +insched=grudge +inlog=... +frame=900
    python scripts/mame_input_trace.py grudge 900 --compare debug/grudge-input/rtl.trace

Modes and the register each reads: grudge 9400 (steering), gun 9902 (IN0,
Night Stocker's gun bits), teamht 9404 (the multiplexed inputs), stompin 9400
(the ADC reading the pads). The schedule is in scripts/mame/inputtrace.lua and
sim/board_tb/tb_board.sv; it changes every HOLD frames. MAME's frame notifier
and the bench's frame counter are not at the same point in the frame, so the
first two frames after each change are left out of the comparison.
"""
import argparse
import sys
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_boot_trace import run_traced, check  # noqa: E402

MODES = {"grudge": "9400", "gun": "9902", "teamht": "9404", "stompin": "9400"}
MODE_OF = {"grudge": "grudge", "nstocker": "gun", "teamht": "teamht", "stompin": "stompin"}
HOLD = 8


def load(path):
    """frame -> list of read values"""
    reads = defaultdict(list)
    for ln in Path(path).read_text().splitlines():
        p = ln.split()
        if p and p[0] == "r":
            reads[int(p[1])].append(p[2].upper())
    return reads


def compare(mame, rtl, frames):
    """The two read streams, aligned. The bench counts a frame from line 0 and
    MAME's frame notifier fires at a different line, so the same read carries a
    different frame number on each side and the streams are offset by a few
    reads. The alignment is the offset with the fewest differences; a
    difference is then either in the frame where the schedule steps (the two
    sides apply a step at different points in the frame) or a real one."""
    def stream(path):
        d = load(path)
        return [(fr, v) for fr in sorted(d) for v in d[fr]]
    m, r = stream(mame), stream(rtl)
    best = None
    for off in range(-32, 33):
        a, b = m[max(0, off):], r[max(0, -off):]
        n = min(len(a), len(b))
        d = sum(1 for i in range(n) if a[i][1] != b[i][1])
        if best is None or d < best[1]:
            best = (off, d, n)
    off, _, n = best
    a, b = m[max(0, off):], r[max(0, -off):]
    step = real = 0
    shown = 0
    for i in range(n):
        if a[i][1] == b[i][1]:
            continue
        if b[i][0] % HOLD in (HOLD - 1, 0, 1):
            step += 1
            continue
        real += 1
        if shown < 8:
            shown += 1
            print(f"  read {i}: MAME frame {a[i][0]} {a[i][1]}, RTL frame {b[i][0]} {b[i][1]}")
    print(f"{n} reads compared (offset {off}): {n - step - real} match, {step} differ "
          f"in the frame the schedule steps, {real} differ elsewhere")
    return real


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("frames", type=int)
    ap.add_argument("--compare", help="the bench's +inlog file")
    ap.add_argument("--seconds", type=int, default=600)
    a = ap.parse_args()
    mode = MODE_OF[a.game]
    out = REPO / "debug" / f"{a.game}-input"
    trace = out / f"{a.game}_input.trace"
    if a.compare:
        return 1 if compare(trace, a.compare, a.frames) else 0
    r = run_traced(a.game, "inputtrace.lua", out,
                   {"CORE_FRAMES": str(a.frames), "CORE_MODE": mode,
                    "CORE_ADDR": MODES[mode], "CORE_HOLD": str(HOLD)}, a.seconds)
    check(trace, r)
    if "MISSING" in trace.read_text():
        sys.exit("some schedule fields were not found; see the trace")
    return 0


if __name__ == "__main__":
    sys.exit(main())
