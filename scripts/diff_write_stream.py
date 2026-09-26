#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The main board's output writes, RTL against MAME, as one flat stream.

    python scripts/diff_write_stream.py debug/cshift-sys/cshift_sys.trace \\
        debug/board-700/writes.log [--skip 98E0] [--context 4]

MAME side: scripts/mame_sys_trace.py. RTL side: sim/board_tb with +wlog=.
Only video RAM, palette, I/O and the sprite list (0x0800 up, 0x0000-0x00ff)
are compared; work RAM and the stack reorder with where an interrupt lands
(docs/MAME_KLUDGES.md, mc6809i). --skip drops addresses whose writes move for
the same reason, the watchdog in particular. Prints the first difference, or
that one stream is a prefix of the other.
"""
import argparse


def keep(a, skip):
    return (a >= 0x0800 or a <= 0x00ff) and a not in skip


def load_mame(path, skip):
    out, frame = [], 0
    for ln in open(path):
        if ln.startswith("# frame"):
            frame = int(ln.split()[2])
            continue
        if ln.startswith("#"):
            continue
        p = ln.rstrip("\n").split("\t")
        if len(p) >= 5 and p[1] == "w" and keep(int(p[2], 16), skip):
            out.append((int(p[2], 16), int(p[4], 16), frame))
    return out


def load_rtl(path, skip):
    out, frame = [], 0
    for ln in open(path):
        if ln.startswith("# frame"):
            frame = int(ln.split()[2])
            continue
        p = ln.rstrip("\n").split("\t")
        if len(p) == 3 and keep(int(p[1], 16), skip):
            out.append((int(p[1], 16), int(p[2], 16), frame))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mame")
    ap.add_argument("rtl")
    ap.add_argument("--skip", default="", help="comma-separated hex addresses")
    ap.add_argument("--context", type=int, default=3)
    a = ap.parse_args()
    skip = {int(x, 16) for x in a.skip.split(",") if x}
    m, r = load_mame(a.mame, skip), load_rtl(a.rtl, skip)
    print(f"MAME {len(m)} writes, RTL {len(r)}")
    n = min(len(m), len(r))
    for i in range(n):
        if m[i][:2] != r[i][:2]:
            print(f"first difference at write #{i}")
            for j in range(max(0, i - a.context), min(n, i + a.context + 1)):
                mark = "  <<" if m[j][:2] != r[j][:2] else ""
                print(f"  {j:7d}  MAME {m[j][0]:04X}={m[j][1]:02X} f{m[j][2]}"
                      f"  RTL {r[j][0]:04X}={r[j][1]:02X} f{r[j][2]}{mark}")
            return 1
    print(f"identical for {n} writes; the shorter stream is a prefix of the longer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
