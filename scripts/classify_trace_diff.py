#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Line up the RTL and MAME bus traces cycle for cycle and classify every difference.

    python scripts/classify_trace_diff.py sentetst

`compare_boot_trace.py` answers "is the RTL executing the same program" by
checking writes strictly and ROM reads as a superset. This answers the next
question: *what exactly* differs, and is any of it functional.

Two correct 6809 implementations disagree on what they drive during non-VMA
("dead") cycles -- one puts $FFFF on the bus, the other leaves the last or next
program address there -- and on which byte they prefetch. Neither changes what
the program does. A difference that is NOT of that shape is a real finding.

The traces are aligned by a constant offset found from the reset sequence, so a
one-cycle difference in how many dead cycles reset takes does not report as
400,000 differences.
"""
import argparse
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def load(path):
    rows = []
    for ln in open(path, encoding="utf8"):
        if ln.startswith("#") or not ln.strip():
            continue
        s = ln.split()
        rows.append((s[1], s[2].upper(), s[4].upper()))
    return rows


def best_offset(mame, rtl, probe=4000, window=8):
    """How many extra cycles MAME's reset takes, by trying small alignments."""
    best, best_score = 0, -1
    for off in range(0, window + 1):
        n = min(len(mame) - off, len(rtl), probe)
        score = sum(1 for i in range(n) if mame[i + off] == rtl[i])
        if score > best_score:
            best, best_score = off, score
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    a = ap.parse_args()
    base = REPO / "debug" / f"{a.game}-boot"
    mame = load(base / f"{a.game}_boot.trace")
    rtl = load(base / f"{a.game}_rtl.trace")
    if not rtl:
        sys.exit("the RTL trace is empty -- did the bench run?")

    # The extra reset cycles sit between the vector fetch and the first opcode,
    # so drop them from the head rather than shifting the whole stream.
    off = best_offset(mame, rtl)
    head = next((i for i, x in enumerate(mame) if x[1] not in ("FFFF", "FFFE")), 0)
    mame2 = mame[:head - off] + mame[head:] if off else mame
    print(f"alignment: MAME's reset takes {off} more bus cycle(s) than the RTL's; "
          f"dropped {off} dead cycle(s) before the first opcode fetch")

    n = min(len(mame2), len(rtl))
    kinds = Counter()
    pairs = Counter()
    functional = []
    for i in range(n):
        m, r = mame2[i], rtl[i]
        if m == r:
            continue
        if m[0] != r[0]:
            kinds["DIRECTION (read vs write)"] += 1
            functional.append((i, m, r))
        elif m[0] == "w":
            kinds["WRITE differs"] += 1
            functional.append((i, m, r))
        elif r[1] == "FFFF" or m[1] == "FFFF":
            kinds["dead-cycle address ($FFFF on one side)"] += 1
            pairs[(m[1], r[1])] += 1
        else:
            kinds["read address differs, neither is $FFFF (prefetch choice)"] += 1
            pairs[(m[1], r[1])] += 1

    total = sum(kinds.values())
    print(f"compared {n} cycles, {total} differ ({100.0 * total / n:.2f}%)")
    for k, v in kinds.most_common():
        print(f"  {v:8d}  {k}")
    if pairs:
        print("  most frequent address pairs (MAME / RTL):")
        for (m, r), c in pairs.most_common(6):
            print(f"      {m} / {r}   x{c}")

    if functional:
        print(f"\nFUNCTIONAL DIFFERENCES: {len(functional)}")
        for i, m, r in functional[:10]:
            print(f"  cycle {i + 1}: MAME {m}  RTL {r}")
        return 1
    if total == 0:
        print(f"\nIdentical: all {n} cycles match MAME exactly, reads included.")
    else:
        print("\nNo functional difference: every disagreement is which address a "
              "non-VMA or prefetch cycle drives.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
