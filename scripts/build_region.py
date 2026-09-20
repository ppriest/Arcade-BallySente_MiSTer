#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build one ROM_REGION's image for a set, straight from the driver's ROM_START.

    python scripts/build_region.py sentetst maincpu
    -> debug/rom/sentetst_maincpu.bin  and  .hex  (one byte per line, for $readmemh)

This is the image the RTL benches load and the image `.mra` output is checked
against. Nothing here reasons about interleaves: Bally/Sente regions are plain
byte-wide loads, and any record kind that is not handled is an error rather
than a silent gap (LESSONS_LEARNED: a wrong map boots far enough to look fine).

Unfilled bytes are 0x00, which is what MAME's ROM_REGION gives when no
ROM_FILL is present -- the diagnostic cartridge reads its empty bank windows
and must see the same thing the reference does.
"""
import argparse
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import load_env, setting  # noqa: E402
from extract_romstart import blocks, region_records  # noqa: E402


def rom_zips():
    """Every directory a set's zip may live in: the core's roms/, then MAME's."""
    env = load_env(REPO)
    dirs = [REPO / "roms"]
    md = setting("MAME_DIR", None, REPO) or env.get("MAME_DIR")
    if md:
        dirs.append(Path(md) / "roms")
    extra = setting("MAME_ROMPATH", None, REPO) or env.get("MAME_ROMPATH") or ""
    dirs += [Path(p) for p in extra.split(";") if p.strip()]
    return dirs


def find_zip(game):
    for d in rom_zips():
        p = Path(d) / f"{game}.zip"
        if p.is_file():
            return p
    sys.exit(f"{game}.zip not found in: " + ", ".join(str(d) for d in rom_zips()))


def read_member(zf, name, crc):
    """By name, else by CRC -- a merged romset stores a ROM once, under one name."""
    try:
        return zf.read(name)
    except KeyError:
        pass
    if crc is not None:
        for info in zf.infolist():
            if info.CRC == crc:
                return zf.read(info.filename)
    raise KeyError(name)


def build(game, region, driver=None):
    src = Path(driver or setting("MAME_SRC", None, REPO))
    body = blocks(src.read_text(encoding="utf-8", errors="replace")).get(game)
    if body is None:
        sys.exit(f"no ROM_START({game}) in {src}")

    size = None
    for ln in body.splitlines():
        ln = ln.split("//")[0].strip()
        if ln.startswith("ROM_REGION") and f'"{region}"' in ln:
            size = int(ln.split("(", 1)[1].split(",")[0].strip(), 16)
            break
    if size is None:
        sys.exit(f"{game} has no ROM_REGION for {region!r}")

    records, unknown = region_records(body, region)
    if unknown:
        sys.exit("unparsed ROM records:\n  " + "\n  ".join(unknown))

    img = bytearray(size)
    zf = zipfile.ZipFile(find_zip(game))
    last = None       # the file a ROM_CONTINUE/ROM_RELOAD carries on from
    consumed = 0      # how much of it a ROM_CONTINUE has already taken
    for rec in records:
        kind, name, off, length = rec[0], rec[1], rec[2], rec[3]
        crc = rec[4] if len(rec) > 4 else None
        if kind == "load":
            data = read_member(zf, name, crc)
            last, consumed = data, length
            img[off:off + length] = data[:length]
        elif kind == "continue":
            if last is None:
                sys.exit("ROM_CONTINUE with no preceding ROM_LOAD")
            img[off:off + length] = last[consumed:consumed + length]
            consumed += length
        elif kind == "reload":
            if last is None:
                sys.exit("ROM_RELOAD with no preceding ROM_LOAD")
            img[off:off + length] = last[:length]
        else:
            sys.exit(f"record kind {kind!r} is not handled for this driver")

    out = REPO / "debug" / "rom"
    out.mkdir(parents=True, exist_ok=True)
    binp = out / f"{game}_{region}.bin"
    binp.write_bytes(img)
    hexp = out / f"{game}_{region}.hex"
    hexp.write_text("".join(f"{b:02x}\n" for b in img), encoding="ascii")
    nz = sum(1 for b in img if b)
    print(f"{game} {region}: {size} bytes, {nz} non-zero ({100.0 * nz / size:.1f}%) -> {binp}")
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("region", nargs="?", default="maincpu")
    ap.add_argument("--driver", help="the MAME driver .cpp (default: MAME_SRC)")
    a = ap.parse_args()
    build(a.game, a.region, a.driver)
    return 0


if __name__ == "__main__":
    sys.exit(main())
