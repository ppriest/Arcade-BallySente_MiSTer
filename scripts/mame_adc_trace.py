#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The ADC's selects and reads under known port values, from MAME, for sim/adc_tb.

    python scripts/mame_adc_trace.py minigolf 900
    -> debug/adc/minigolf_adc.trace, debug/adc/minigolf_adc.vec

The .vec file is what the bench reads, one event per line, times in 40 MHz
clk_sys cycles from the first event:

    v <cycle> <an0> <an1> <an2> <an3>   port values, two's complement bytes, hex
    s <cycle> <channel>
    r <cycle> <data> <check>            check 0: the read falls in the frame after
                                        a "v", before the board has latched it
The second line is "c <shift> <raw>", the set's config_shooter_adc().
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_boot_trace import run_traced, check  # noqa: E402
import build_mra  # noqa: E402

CLK = 40_000_000
FRAME = 1 / 60


def vectors(trace, adc):
    ev = []
    for ln in trace.read_text().splitlines():
        if ln.startswith("#"):
            continue
        p = ln.split()
        ev.append((p[0], float(p[1]), [int(x) for x in p[2:]]))
    t0 = ev[0][1]
    out = [f"c {adc & 3} {adc >> 7 & 1}"]
    last_v = -1.0
    for kind, t, a in ev:
        cyc = round((t - t0) * CLK)
        if kind == "v":
            last_v = t
            out.append(f"v {cyc} " + " ".join(f"{x & 0xff:02x}" for x in a))
        elif kind == "s":
            out.append(f"s {cyc} {a[0]}")
        else:
            out.append(f"r {cyc} {a[0]:02x} {0 if t - last_v < FRAME * 1.05 else 1}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("frames", type=int)
    ap.add_argument("--hold", type=int, default=4, help="frames per set of port values")
    ap.add_argument("--seconds", type=int, default=300)
    a = ap.parse_args()
    out = REPO / "debug" / "adc"
    r = run_traced(a.game, "adctrace.lua", out / a.game,
                   {"CORE_FRAMES": str(a.frames), "CORE_HOLD": str(a.hold)}, a.seconds)
    trace = out / a.game / f"{a.game}_adc.trace"
    check(trace, r)
    text = build_mra.driver_text()
    adc = build_mra.adc_config(text, build_mra.game_line(text, a.game)["init"])
    vec = vectors(trace, adc)
    path = out / f"{a.game}_adc.vec"
    path.write_text("\n".join(vec) + "\n")
    reads = [v for v in vec if v.startswith("r")]
    print(f"{len(reads)} reads, {sum(v.endswith(' 1') for v in reads)} checked -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
