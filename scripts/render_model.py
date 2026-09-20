#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Software model of the Bally/Sente video hardware, ported from MAME.

    python scripts/render_model.py sentetst-diag
    python scripts/render_model.py --all
    -> debug/<capture>/model.png and a pixel diff against MAME's reference.png

WORKFLOW section 9: the model comes before the RTL, the model is checked against
MAME, and the RTL is checked against the model. This is that model, and it is a
line-by-line port of `src/mame/bally/balsente_v.cpp` at MAME 0.289 -- the same
discipline `scripts/cem3394_model.py` follows for the sound chip.

Inputs are one directory from `scripts/mame_capture.py`:

    videoram.bin      0x0800-0x7fff, the 256x240 4bpp packed bitmap
    paletteram.bin    0x8000-0x8fff, 1024 entries of 4 bytes
    spriteram.bin     0x0000-0x00ff, the 40-entry sprite list
    scan_palbank.txt  every write to 0x98c0-0x98df, with its raster position
    reference.png     what MAME drew

plus the `gfx1` sprite ROM, from `scripts/build_region.py <set> gfx1`.

EVERY RUN PRINTS COVERAGE, because "0 pixels differ" on a frame that drew no
sprites says nothing about the sprite path -- and the first capture taken for
this core was exactly that: 40 entries all pointing at image 0, which is blank.
A scene is only evidence for the paths it actually ran.

THE PARTS THAT ARE EASY TO GET WRONG, all of them read out of balsente_v.cpp
rather than reasoned about:

  * A sprite pixel is not a colour. It is the HIGH nibble of a palette index and
    the bitmap underneath supplies the low nibble, so a sprite recolours what is
    under it. A sprite nibble of 0 is transparent.
  * Sprite Y is offset by 17 and then by VBEND, and wraps at 256 per row, so a
    sprite can be split across the top and bottom of the screen.
  * Rows landing above 16 + VBEND are skipped, but the source pointer still
    advances past them.
  * The background pointer a sprite row reads is a FLAT index into the expanded
    bitmap, `(ypos - VBEND) * 256 + xpos`, so a sprite near the right edge reads
    its background from the start of the next line. Pixels are still clipped to
    x < 256, so this only matters if a future MAME changes the clip.
  * Palette entries are four bytes, big-endian on this board's 6809 bus, and the
    decoder takes R from byte 0, G from byte 1, B from byte 2. Byte 3 is unused.
    4 bits per channel expand as (v << 4) | v.
"""
import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# balsente.h
VBEND = 0x10
VBSTART = 0x100
VTOTAL = 0x108
WIDTH = 256
HEIGHT = VBSTART - VBEND          # 240 visible lines


# --------------------------------------------------------------- raster state

def read_scanlog(path):
    """scan_<reg>.txt from scripts/mame/capture.lua: frame, lines until vblank
    starts, data. The Lua binding has no screen:vpos() -- luaengine.cpp's
    screen_dev_type binds the periods and time_until_vblank_start and nothing
    positional -- so the raster line is reconstructed here, where the board's
    geometry is known."""
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f, ltv, data = line.split("\t")
        vpos = (VBSTART + VTOTAL - float(ltv)) % VTOTAL
        rows.append((int(f), vpos, int(data)))
    return rows


def banks_for_frame(scanlog, frame, default=0):
    """The palette bank per visible line for one frame.

    palette_select_w calls `update_partial(vpos - 1 + BALSENTE_VBEND)`, which
    renders everything through that ABSOLUTE scanline with the old bank; the new
    one takes effect on the next. vpos() is already absolute, so adding VBEND
    again puts the boundary 16 lines below the write -- measured, and recorded
    in docs/MAME_KLUDGES.md. In visible-row terms the boundary is simply vpos.
    """
    bank = default
    for f, _vpos, data in scanlog:
        if f < frame:
            bank = data & 3
    per_line = [bank] * HEIGHT
    for f, vpos, data in scanlog:
        if f != frame:
            continue
        first = max(0, min(HEIGHT, int(vpos)))
        for y in range(first, HEIGHT):
            per_line[y] = data & 3
    return per_line


# -------------------------------------------------------------------- colour

def pal4bit(v):
    v &= 0x0f
    return (v << 4) | v


def decode_palette(paletteram):
    """1024 pens as (r, g, b). standard_rgb_decoder<4,4,4, 24,16,8> over a
    big-endian 4-byte entry puts R in byte 0, G in byte 1, B in byte 2."""
    return [(pal4bit(paletteram[4 * n]),
             pal4bit(paletteram[4 * n + 1]),
             pal4bit(paletteram[4 * n + 2])) for n in range(1024)]


def expand_videoram(videoram):
    """videoram_w: each byte is two pixels, high nibble first."""
    ex = bytearray(WIDTH * HEIGHT)
    for i, d in enumerate(videoram):
        ex[2 * i] = d >> 4
        ex[2 * i + 1] = d & 15
    return ex


# ------------------------------------------------------------------ coverage

COVER_KEYS = ("sprites_drawn", "sprite_pixels", "flipx", "flipy",
              "y_wrapped", "x_clipped", "rows_above_screen")


def new_coverage():
    c = {k: 0 for k in COVER_KEYS}
    c.update(entries_live=0, images=set(), sprite_nibbles=set(),
             bg_nibbles=set(), banks=set())
    return c


def coverage_line(c):
    return (f"sprites {c['sprites_drawn']}/{c['entries_live']} drew "
            f"{c['sprite_pixels']} px | flipX {c['flipx']} flipY {c['flipy']} | "
            f"Ywrap {c['y_wrapped']} Xclip {c['x_clipped']} "
            f"above-screen {c['rows_above_screen']} | "
            f"images {len(c['images'])} | sprite nibbles {len(c['sprite_nibbles'])}/15 "
            f"| banks {sorted(c['banks'])}")


# ------------------------------------------------------------------- sprites

def draw_one_sprite(idx, ex, sprite, gfx, gfx_mask, cov):
    """balsente_v.cpp draw_one_sprite(), writing palette INDICES rather than
    pens so the caller can pick the bank per line."""
    flags = sprite[0]
    image = sprite[1] | ((flags & 7) << 8)
    ypos = sprite[2] + 17 + VBEND
    xpos = sprite[3]

    src = (64 * image) & gfx_mask
    if flags & 0x80:
        src += 4 * 15

    live = any(gfx[((64 * image) & gfx_mask) + k] for k in range(64))
    if live:
        cov["entries_live"] += 1
        cov["images"].add(image)
        if flags & 0x40:
            cov["flipx"] += 1
        if flags & 0x80:
            cov["flipy"] += 1
    drew = 0

    def put(nib, currx, old):
        nonlocal drew
        if not nib:
            return
        if 0 <= currx < WIDTH:
            idx[row * WIDTH + currx] = nib | ex[old]
            cov["sprite_nibbles"].add(nib >> 4)
            cov["bg_nibbles"].add(ex[old])
            drew += 1
        else:
            cov["x_clipped"] += 1

    for _ in range(16):
        # cliprect is the whole visible area: min_y = VBEND, max_y = VBSTART - 1
        if ypos >= (16 + VBEND) and VBEND <= ypos <= VBSTART - 1:
            row = ypos - VBEND
            old = row * WIDTH + xpos
            currx = xpos
            if not (flags & 0x40):
                for _x in range(4):
                    ipixel = gfx[src]
                    src += 1
                    put(ipixel & 0xf0, currx, old)
                    put((ipixel << 4) & 0xf0, currx + 1, old + 1)
                    currx += 2
                    old += 2
            else:
                src += 4
                for _x in range(4):
                    src -= 1
                    ipixel = gfx[src]
                    put((ipixel << 4) & 0xf0, currx, old)
                    put(ipixel & 0xf0, currx + 1, old + 1)
                    currx += 2
                    old += 2
                src += 4
        else:
            src += 4
            if live and ypos < (16 + VBEND):
                cov["rows_above_screen"] += 1
        if flags & 0x80:
            src -= 2 * 4
        prev = ypos
        ypos = (ypos + 1) & 255
        if live and ypos < prev:
            cov["y_wrapped"] += 1

    cov["sprite_pixels"] += drew
    if drew:
        cov["sprites_drawn"] += 1


def render(videoram, paletteram, spriteram, gfx, palbank, bank_of_line=None,
           cov=None):
    """One frame, as RGB bytes. `bank_of_line` overrides `palbank` per visible
    line, for the frames where the game switches bank mid-screen."""
    if cov is None:
        cov = new_coverage()
    ex = expand_videoram(videoram)
    pens = decode_palette(paletteram)
    gfx_mask = len(gfx) - 1

    # The background is the expanded bitmap straight through.
    idx = bytearray(ex)

    # 40 sprites from 0xe0, wrapping in the low 256 bytes. Later sprites
    # overwrite earlier ones: there is no priority, only order.
    for i in range(40):
        p = (0xe0 + i * 4) & 0xff
        draw_one_sprite(idx, ex, spriteram[p:p + 4], gfx, gfx_mask, cov)

    if bank_of_line is None:
        bank_of_line = [palbank] * HEIGHT
    cov["banks"].update(bank_of_line)

    out = bytearray(WIDTH * HEIGHT * 3)
    for y in range(HEIGHT):
        base = bank_of_line[y] * 256
        row = y * WIDTH
        for x in range(WIDTH):
            r, g, b = pens[base + idx[row + x]]
            o = (row + x) * 3
            out[o] = r
            out[o + 1] = g
            out[o + 2] = b
    return out, cov


# -------------------------------------------------------- racing the beam

HTOTAL = 0x140          # 320 pixel clocks a line


def read_beamlog(path, base):
    """beam_<region>.txt: lines until vblank, address, data, for ONE frame.
    Returns (beam_position, offset_within_region, data), sorted, where the beam
    position is line * HTOTAL + pixel."""
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        ltv, addr, data = line.split("\t")
        vpos = (VBSTART + VTOTAL - float(ltv)) % VTOTAL
        line_no = int(vpos)
        pix = int((vpos - line_no) * HTOTAL)
        rows.append((line_no * HTOTAL + pix, int(addr, 16) - base, int(data, 16)))
    rows.sort(key=lambda r: r[0])
    return rows


def sprite_rows(sprite):
    """The 16 (row index, absolute scanline) pairs MAME's draw_one_sprite walks.

    The first ypos is NOT masked -- `sprite[2] + 17 + BALSENTE_VBEND` reaches 288
    -- and only the increment is, so a sprite placed near the bottom has its
    first rows land above 255 where the cliprect rejects them, and the rest wrap
    to the top of the screen. Reproduced rather than tidied.
    """
    ypos = sprite[2] + 17 + VBEND
    out = []
    for k in range(16):
        out.append((k, ypos))
        ypos = (ypos + 1) & 255
    return out


def render_beam(start, gfx, writes, scanlog, frame, sprite_latency=1):
    """One frame the way the board draws it: scanned out line by line from RAM
    that the CPU is writing at the same time.

    `start` is the three regions as they stood at the first line of the frame;
    `writes` maps a region name to (beam position, offset, data). The background
    and the palette are read AT SCANOUT, so a write lands mid-line and the rest
    of that line shows the new value. The sprite line buffer is filled during the
    previous line, so a sprite-RAM write takes effect `sprite_latency` lines
    later -- an ASSUMPTION about the board, recorded in docs/HACKS.md, because
    MAME models none of this and there is nothing to check it against.
    """
    vram = bytearray(start["videoram"])
    sram = bytearray(start["spriteram"])
    pram = bytearray(start["paletteram"])
    gfx_mask = len(gfx) - 1
    per_line = banks_for_frame(scanlog, frame)

    wv = writes.get("videoram", [])
    ws = writes.get("spriteram", [])
    wp = writes.get("paletteram", [])
    iv = ip = 0
    # Sprite RAM is applied a whole line at a time, `sprite_latency` lines early,
    # so the line buffer is built from the state the beam had then.
    isp = 0

    out = bytearray(WIDTH * HEIGHT * 3)
    cov = new_coverage()

    for y in range(HEIGHT):
        vpos = y + VBEND
        # sprite RAM as of the line whose buffer feeds this one
        cut = (vpos - sprite_latency + 1) * HTOTAL
        while isp < len(ws) and ws[isp][0] < cut:
            sram[ws[isp][1]] = ws[isp][2]
            isp += 1

        # the sprite line buffer: nibble plus a written flag, never the composed
        # index, because each sprite reads its low nibble from the BACKGROUND
        sbuf = bytearray(WIDTH)
        for i in range(40):
            p = (0xe0 + i * 4) & 0xff
            sp_ = sram[p:p + 4]
            image = sp_[1] | ((sp_[0] & 7) << 8)
            if not any(gfx[((64 * image) & gfx_mask) + k] for k in range(64)):
                continue
            flags = sp_[0]
            xpos = sp_[3]
            for k, yy in sprite_rows(sp_):
                if yy != vpos or yy < (16 + VBEND):
                    continue
                base = (64 * image) & gfx_mask
                row = (15 - k) if (flags & 0x80) else k
                src = base + 4 * row
                currx = xpos
                for b in range(4):
                    ipixel = gfx[src + (3 - b)] if (flags & 0x40) else gfx[src + b]
                    if flags & 0x40:
                        left, right = (ipixel << 4) & 0xf0, ipixel & 0xf0
                    else:
                        left, right = ipixel & 0xf0, (ipixel << 4) & 0xf0
                    for nib in (left, right):
                        if nib and 0 <= currx < WIDTH:
                            sbuf[currx] = nib
                            cov["sprite_nibbles"].add(nib >> 4)
                        elif nib:
                            cov["x_clipped"] += 1
                        currx += 1
                cov["sprite_pixels"] += 1

        base_pen = per_line[y] * 256
        for x in range(WIDTH):
            pos = vpos * HTOTAL + x
            while iv < len(wv) and wv[iv][0] <= pos:
                vram[wv[iv][1]] = wv[iv][2]
                iv += 1
            while ip < len(wp) and wp[ip][0] <= pos:
                pram[wp[ip][1]] = wp[ip][2]
                ip += 1
            b = vram[y * 128 + (x >> 1)]
            bg = (b >> 4) if (x & 1) == 0 else (b & 15)
            idx = (sbuf[x] | bg) if sbuf[x] else bg
            n = base_pen + idx
            o = (y * WIDTH + x) * 3
            out[o] = pal4bit(pram[4 * n])
            out[o + 1] = pal4bit(pram[4 * n + 1])
            out[o + 2] = pal4bit(pram[4 * n + 2])
    cov["banks"].update(per_line)
    return out, cov


# ---------------------------------------------------------------------- main

def load_capture(d):
    def rd(name):
        p = d / name
        if not p.exists():
            sys.exit(f"{p} is missing -- run scripts/mame_capture.py first")
        return p.read_bytes()
    man = {}
    for line in (d / "manifest.txt").read_text().splitlines():
        k, _, v = line.partition(" ")
        man[k] = v
    return (rd("videoram.bin"), rd("paletteram.bin"), rd("spriteram.bin"), man)


def check(name, bank_override=None, gfx_override=None, quiet=False):
    from PIL import Image
    d = REPO / "debug" / name
    if not d.is_dir():
        sys.exit(f"no such capture: {d}")
    videoram, paletteram, spriteram, man = load_capture(d)

    gfx_path = Path(gfx_override) if gfx_override else \
        REPO / "debug" / "rom" / f"{man['set']}_gfx1.bin"
    if not gfx_path.exists():
        sys.exit(f"{gfx_path} is missing -- run: python scripts/build_region.py "
                 f"{man['set']} gfx1")
    gfx = gfx_path.read_bytes()

    frame = int(man.get("frame", 0))
    per_line = banks_for_frame(read_scanlog(d / "scan_palbank.txt"), frame)
    if bank_override is not None:
        per_line = [bank_override] * HEIGHT
    changes = [(y, b) for y, b in enumerate(per_line)
               if y == 0 or b != per_line[y - 1]]

    rgb, cov = render(videoram, paletteram, spriteram, gfx, per_line[0], per_line)

    Image.frombytes("RGB", (WIDTH, HEIGHT), bytes(rgb)).save(d / "model.png")

    # reference.png is MAME's composited snapshot and reference.bin is the
    # screen's own bitmap from scr:pixels(). The .png is the one to diff
    # against: measured on two captures, it is rendered from the same state as
    # the RAM dump, while the .bin lags by whatever the CPU wrote between the
    # screen update and the capture -- 15 pixels on cshift frame 3000 and 231
    # on stocker frame 1784. The .bin is kept, and the gap reported, so that
    # staleness stays visible instead of being something to rediscover.
    ref = Image.open(d / "reference.png").convert("RGB")
    if ref.size != (WIDTH, HEIGHT):
        sys.exit(f"reference.png is {ref.size}, expected {(WIDTH, HEIGHT)}")
    rb = ref.tobytes()

    stale = 0
    rawp = d / "reference.bin"
    if rawp.exists():
        raw = rawp.read_bytes()
        if len(raw) == WIDTH * HEIGHT * 4:
            bb = bytes(b for i in range(0, len(raw), 4)
                       for b in (raw[i + 2], raw[i + 1], raw[i]))
            stale = sum(1 for i in range(0, len(bb), 3) if bb[i:i + 3] != rb[i:i + 3])

    # What MAME drew over the game. This board has 4 bits per channel, expanded
    # as (v << 4) | v, so EVERY pixel the hardware can produce is a multiple of
    # 17 in all three channels. Anything else came from MAME's render pipeline,
    # not from the game -- stocker has an analog wheel and MAME blends a 13x32
    # crosshair into the corner. Those pixels are excluded from the diff and
    # counted out loud, rather than quietly costing a comparison 416 pixels.
    overlay = {i // 3 for i in range(0, len(rb), 3)
               if any(v % 17 for v in rb[i:i + 3])}
    diff = [i // 3 for i in range(0, len(rb), 3)
            if rb[i:i + 3] != bytes(rgb[i:i + 3]) and i // 3 not in overlay]

    if len(changes) > 1:
        where = ", ".join(f"bank {b} from line {y}" for y, b in changes)
        head = f"{name}: {man['set']} frame {frame}, mid-frame: {where}"
    else:
        head = f"{name}: {man['set']} frame {frame}, palette bank {per_line[0]}"
    if not quiet:
        print(head)
        print("  " + coverage_line(cov))
        if overlay:
            rows = sorted({p // WIDTH for p in overlay})
            cols = sorted({p % WIDTH for p in overlay})
            print(f"  NOTE {len(overlay)} pixels of MAME's own overlay excluded "
                  f"(rows {rows[0]}-{rows[-1]}, columns {cols[0]}-{cols[-1]}): "
                  f"colours this 4-bit palette cannot produce")
        if stale:
            print(f"  NOTE reference.bin lags reference.png by {stale} pixels "
                  f"(the CPU wrote between the screen update and the capture)")
    if diff:
        if not quiet:
            print(f"  FAIL {len(diff)} of {WIDTH * HEIGHT} pixels differ "
                  f"({100.0 * len(diff) / (WIDTH * HEIGHT):.3f}%)")
            rows = sorted({p // WIDTH for p in diff})
            cols = sorted({p % WIDTH for p in diff})
            print(f"       rows {rows[0]}-{rows[-1]} ({len(rows)} distinct), "
                  f"columns {cols[0]}-{cols[-1]} ({len(cols)} distinct)")
            for p in diff[:8]:
                o = p * 3
                print(f"       ({p % WIDTH:3d},{p // WIDTH:3d}) MAME "
                      f"{tuple(rb[o:o + 3])} model {tuple(rgb[o:o + 3])}")
            mask = set(diff)
            img = Image.new("RGB", (WIDTH, HEIGHT))
            img.putdata([(255, 0, 0) if (y * WIDTH + x) in mask else (0, 0, 0)
                         for y in range(HEIGHT) for x in range(WIDTH)])
            img.save(d / "diff.png")
            print(f"       -> {d / 'diff.png'}")
    elif not quiet:
        print("  PIXEL-EXACT against MAME")
    return len(diff), cov


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture", nargs="?", help="directory under debug/, e.g. sentetst-diag")
    ap.add_argument("--all", action="store_true", help="every capture that has a reference.png")
    ap.add_argument("--gfx", default=None, help="sprite ROM (default debug/rom/<set>_gfx1.bin)")
    ap.add_argument("--bank", type=int, default=None, help="override the palette bank")
    a = ap.parse_args()

    if a.all:
        names = sorted(p.parent.name for p in (REPO / "debug").glob("*/reference.png"))
        if not names:
            sys.exit("no captures with a reference.png under debug/")
        total = new_coverage()
        bad = 0
        for n in names:
            nd, cov = check(n, a.bank, a.gfx)
            bad += 1 if nd else 0
            for k in COVER_KEYS:
                total[k] += cov[k]
            total["entries_live"] += cov["entries_live"]
            for k in ("images", "sprite_nibbles", "bg_nibbles", "banks"):
                total[k] |= cov[k]
        print(f"\n{len(names) - bad} of {len(names)} captures pixel-exact")
        print("combined coverage: " + coverage_line(total))
        missing = [k for k in ("flipx", "flipy", "y_wrapped", "x_clipped") if not total[k]]
        if missing:
            print("NOT YET EXERCISED BY ANY CAPTURE: " + ", ".join(missing))
        return 1 if bad else 0

    if not a.capture:
        ap.error("give a capture name, or --all")
    nd, _ = check(a.capture, a.bank, a.gfx)
    return 1 if nd else 0


if __name__ == "__main__":
    sys.exit(main())
