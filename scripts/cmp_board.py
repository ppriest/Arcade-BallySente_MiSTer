#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""sim/board_tb's dumps against a MAME capture of the same frame.

    python scripts/cmp_board.py debug/<set>-<frame capture> debug/<bench out dir>

Video RAM, the palette and the sprite list byte for byte, then the picture:
the bench's pix.bin (256 x 240 RGB, the last frame before the dump) against
MAME's reference.bin (the same, RGBA). The picture is also tried shifted by up
to 16 rows either way, since the bench's last frame and MAME's rendered one
can sit a frame apart in how each is counted; the best shift is reported.
"""
import sys
from pathlib import Path

W, H = 256, 240


def main():
    mame, rtl = Path(sys.argv[1]), Path(sys.argv[2])
    for m, r in (("videoram", "vram"), ("paletteram", "pal"), ("spriteram", "sram")):
        a, b = (mame / f"{m}.bin").read_bytes(), (rtl / f"{r}.bin").read_bytes()
        d = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
        print(f"{r:5s} {'same' if not d else f'{len(d)} bytes differ, first at {d[0]:#x}'}")
    ref = (mame / "reference.bin").read_bytes()
    pix = (rtl / "pix.bin").read_bytes() if (rtl / "pix.bin").exists() else None
    if not pix:
        return 0
    # MAME's order: try RGB and BGR in the first three bytes of each pixel
    orders = {"RGBA": (0, 1, 2), "BGRA": (2, 1, 0), "ARGB": (1, 2, 3)}
    best = None
    for name, (ri, gi, bi) in orders.items():
        mref = [(ref[p * 4 + ri], ref[p * 4 + gi], ref[p * 4 + bi]) for p in range(W * H)]
        for shift in range(-16, 17):
            bad = 0
            for y in range(H):
                ys = y + shift
                for x in range(W):
                    q = (pix[(y * W + x) * 3], pix[(y * W + x) * 3 + 1], pix[(y * W + x) * 3 + 2])
                    m_ = mref[ys * W + x] if 0 <= ys < H else (0, 0, 0)
                    if q != m_:
                        bad += 1
            if best is None or bad < best[0]:
                best = (bad, shift, name)
    print(f"pixels: {best[0]} of {W * H} differ at the best alignment "
          f"(rows shifted {best[1]}, MAME order {best[2]})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
