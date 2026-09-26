#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the .mra files, from MAME's own data.

    python scripts/build_mra.py                  # the Phase 2 sets
    python scripts/build_mra.py cshift toggle    # just these
    python scripts/build_mra.py --refresh ...    # re-ask MAME instead of the cache

Everything per-game comes from MAME rather than being typed:

    ROM loads          ROM_START, via scripts/extract_romstart.py
    cartridge wiring   the set's init_*(): expand_roms() mask and SWAP_HALVES
    DIP switches       -listxml, after MAME has merged PORT_INCLUDE/PORT_MODIFY
    input bits         scripts/mame/ports.lua, the same merged fields
    title, year, maker the GAME() line

Nothing here re-parses INPUT_PORTS: scripts/extract_dips.py does not apply
PORT_MODIFY overlaps (cshift's SWG came out with both sentetst's Bonus Life
and cshift's unused switches on the same bits), and MAME already has.

THE INDEX-0 IMAGE, which rtl/balsente_core.sv decodes:

    0x00000  maincpu, padded to 256 KB (MAME fills a region with 0x00)
    0x40000  gfx1, 64 KB
    0x50000  the 6VB's ROM, 8 KB (sente6vb.zip)
    0x52000  configuration, 32 bytes:
               0      expand_roms() mask, low 6 bits
               1      bit 0 SWAP_HALVES, bit 1 a 256 KB maincpu region
               2-5    AN0-AN3 descriptors (rtl/analog_inputs.sv)
               6      ADC: bits 1:0 the shift, bit 7 raw (rtl/adc.sv)
               7-15   0
               16-23  IN0 bits 0-7, one map byte each
               24-31  IN1 bits 0-7 (bit 7 is VBLANK, from the board)

A map byte says where a port bit comes from:
    0x00-0x1f   joystick_0 bit n, active low as MAME's ports are
    0x20-0x3f   joystick_1 bit n
    +0x40       active high instead
    0x80        a DIP: the same bit of <switches> byte 2 (IN0) or 3 (IN1)
    0xfe / 0xff constant 0 / 1

Joystick bits are the core's CONF_STR J1 line: 0 R, 1 L, 2 D, 3 U, 4-7
buttons 1-4, 8 Start, 9 Coin, 10 Service, 11 Pause, 12 Start 3, 13 Start 4
(on player 1's controller: those sets pick the player count on one panel).
<switches> bytes are SWH (0x9900), SWG (0x9901), the DIP bits of IN0 and IN1, then a fifth byte
the board never sees: bit 0 is the fake Flip Screen DIP (BallySente.sv), since
no set has a flip of its own.
"""
import argparse
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import NO_WINDOW, setting          # noqa: E402
from extract_romstart import blocks, region_records  # noqa: E402
from mame_capture import lua_runner_env, mame_cmd, mame_paths  # noqa: E402
import mra                                        # noqa: E402

PHASE2 = ["sentetst", "cshift", "hattrick", "toggle", "gghost"]

# Every set the RTL runs. Left out until their hardware is written: teamht
# (input multiplexer), grudge* (steering), spiker* (expand helper), rescraid*
# (NOVRAM variant), stompin/stompina (pads), nstocker* (light gun), shrike
# (68000), triviaes4/5 (other hardware).
RUNNABLE = PHASE2 + ["otwalls", "snakepit", "snakepita", "snakjack", "stocker",
                     "triviag1", "triviag1a", "triviabb", "triviag2", "triviayp",
                     "triviasp", "triviaes", "triviaes2", "gimeabrk", "minigolf",
                     "minigolfa", "minigolfb", "minigolfct", "sfootbal", "nametune",
                     "nametunea"]

ANALOG_KIND = {"TRACKBALL_X": 1, "TRACKBALL_Y": 2, "DIAL": 3, "AD_STICK_X": 4,
               "AD_STICK_Y": 5}

PRG_SIZE, GFX_SIZE, SND_SIZE = 0x40000, 0x10000, 0x2000
GFX_BASE, SND_BASE, CFG_BASE = 0x40000, 0x50000, 0x52000
IMAGE_SIZE = CFG_BASE + 32

SND_ZIP, SND_ROM, SND_CRC = "sente6vb.zip", "8002-10 9-25-84.5", "4dd0a525"

DIP_BYTE = {":SWH": 0, ":SWG": 1, ":IN0": 2, ":IN1": 3}
J1 = "J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Service,Pause"
JOY = {"RIGHT": 0, "LEFT": 1, "DOWN": 2, "UP": 3}
OSD_COLS = 28

# The game's own names for its buttons, keyed by set; a clone takes its
# parent's. Entry N names MAME's BUTTON(N+1), so keep the order and count; an
# empty list or a missing set keeps "Button N".
BUTTON_NAMES = {
    "cshift":   ["Blue Things", "Red Things"],              # Chicken Shift
    "snakjack": ["Blow"],                                   # Snacks'n Jaxson
    "hattrick": ["Shoot"],                                  # Hat Trick
    "toggle":   ["Shoot"],                                  # Toggle
    "gghost":   ["Jump", "Button 2"],                       # Goalie Ghost
    "otwalls":  [],                                         # Off the Wall (dials only)
    "snakepit": ["Whip"],                                   # Snake Pit
    "stocker":  ["Gas"],                                    # Stocker
    "triviag1": ["Incorrect", "Correct"],                   # Trivial Pursuit (Genus)
    "triviabb": ["Incorrect", "Correct"],                   # Trivial Pursuit (Baby Boomer)
    "triviag2": ["Incorrect", "Correct"],                   # Trivial Pursuit (Genus II)
    "triviayp": ["Incorrect", "Correct"],                   # Trivial Pursuit (Young Players)
    "triviasp": ["Incorrect", "Correct"],                   # Trivial Pursuit (All Star Sports)
    "triviaes": ["Incorrect", "Correct"],                   # Trivial Pursuit (Spanish)
    "gimeabrk": ["Position Cue Ball"],                      # Gimme A Break
    "minigolf": ["Tee Select"],                             # Mini Golf
    "sfootbal": ["Jump/Spike"],                             # Street Football
    "nametune": ["1", "2", "3", "4"],  # Name That Tune
    "sentetst": ["Button 1"],                               # Sente Diagnostic Cartridge
}

OUT = REPO / "releases"
CACHE = REPO / "debug" / "mame"


def out_dir(game, parent):
    """Parents in releases/, clones in releases/_alternatives/."""
    return OUT / "_alternatives" if parent else OUT


# ----------------------------------------------------------------- MAME
def listxml(game, refresh):
    path = CACHE / f"{game}.xml"
    if refresh or not path.exists():
        mame_dir, exe = mame_paths()
        r = subprocess.run([str(exe), "-listxml", game], cwd=mame_dir, capture_output=True,
                           text=True, **NO_WINDOW)
        if r.returncode:
            sys.exit(f"mame -listxml {game} failed: {r.stderr[-500:]}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(r.stdout, encoding="utf-8")
    root = ET.parse(path).getroot()
    for m in root.findall("machine"):
        if m.get("name") == game:
            return root, m
    sys.exit(f"{game} is not in MAME's -listxml")


def ports(game, refresh):
    """[(tag, mask, default, token)] from scripts/mame/ports.lua."""
    path = REPO / "debug" / "ports" / f"{game}.txt"
    if refresh or not path.exists():
        mame_dir, exe = mame_paths()
        path.parent.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ, **lua_runner_env("ports.lua"), PORTS_FILE=str(path.resolve()),
                   CORE_OUT=str(path.parent.resolve()))
        subprocess.run(mame_cmd(exe, game, "ports.lua", mame_dir, ["-seconds_to_run", "5"]),
                       cwd=mame_dir, env=env, capture_output=True, text=True, **NO_WINDOW)
        if not path.exists():
            sys.exit(f"ports.lua wrote nothing for {game}")
    out = set()
    for ln in path.read_text().splitlines():
        f = ln.split("\t")
        out.add((f[0], int(f[1]), int(f[2]), f[3]))
    return sorted(out)


# ------------------------------------------------------------ the driver
def driver_text():
    src = setting("MAME_SRC")
    if not src:
        sys.exit("MAME_SRC is not set (mister.env)")
    return Path(src).read_text(encoding="utf-8", errors="replace")


def game_line(text, game):
    m = re.search(r"^GAMEL?\(\s*(\d+|19\?\?),\s*" + re.escape(game) + r"\s*,\s*(\w+),\s*(\w+),\s*(\w+),"
                  r"\s*\w+,\s*(\w+),\s*(ROT\d+),\s*\"([^\"]*)\",\s*\"([^\"]*)\"", text, re.M)
    if not m:
        sys.exit(f"no GAME() line for {game}")
    year, parent, machine, inp, init, rot, maker, title = m.groups()
    return dict(year=year, parent=None if parent == "0" else parent, machine=machine,
                inp=inp, init=init, rot=rot, maker=maker, title=title)


def analog_ports(text, inp):
    """AN0-AN3 for an INPUT_PORTS block, following PORT_INCLUDE: (kind, player,
    reverse, half) per port, or None. MAME's Lua does not expose PORT_REVERSE,
    so this reads the driver; each analog port holds one 8-bit field, so a
    later definition of a port replaces an earlier one whole."""
    blocks_ = {m.group(1): m.group(2) for m in
               re.finditer(r"INPUT_PORTS_START\(\s*(\w+)\s*\)(.*?)INPUT_PORTS_END", text, re.S)}

    def resolve(name):
        body = blocks_[name]
        inc = re.search(r"PORT_INCLUDE\(\s*(\w+)\s*\)", body)
        ports_ = dict(resolve(inc.group(1))) if inc else {}
        cur = None
        for ln in body.splitlines():
            ln = ln.split("//")[0]
            t = re.search(r'PORT_(?:START|MODIFY)\(\s*"(\w+)"\s*\)', ln)
            if t:
                cur = t.group(1)
                continue
            if cur not in ("AN0", "AN1", "AN2", "AN3"):
                continue
            if "UNUSED_ANALOG" in ln:
                ports_[cur] = None
                continue
            k = re.search(r"IPT_(\w+)", ln)
            if k and "PORT_BIT" in ln:
                if k.group(1) == "UNUSED":
                    ports_[cur] = None
                else:
                    pl = re.search(r"PORT_PLAYER\((\d)\)", ln)
                    sens = re.search(r"PORT_SENSITIVITY\((\d+)\)", ln)
                    ports_[cur] = (k.group(1), int(pl.group(1)) - 1 if pl else 0,
                                   "PORT_REVERSE" in ln,
                                   bool(sens) and int(sens.group(1)) <= 50)
        return ports_

    p = resolve(inp)
    return [p.get(f"AN{i}") for i in range(4)]


def analog_bytes(ports_):
    out = []
    for p in ports_:
        if p is None:
            out.append(0)
            continue
        kind, pl, rev, half = p
        if kind not in ANALOG_KIND:
            sys.exit(f"analog port type IPT_{kind} is not wired")
        out.append((0x80 if rev else 0) | (0x40 if half else 0) | (ANALOG_KIND[kind] << 3) | pl)
    return out


def adc_config(text, init):
    """config_shooter_adc(shooter, shift): the ADC byte, bits 1:0 the shift,
    bit 7 raw for MAME's shift of 32."""
    m = re.search(r"void balsente_state::" + re.escape(init) +
                  r"\(\)\s*\{[^}]*config_shooter_adc\(\s*(true|false)\s*,\s*(\d+)", text)
    if not m:
        return 0
    if m.group(1) == "true":
        sys.exit(f"{init}: a light-gun set; its shooter logic is not wired")
    shift = int(m.group(2))
    return 0x80 if shift == 32 else shift


def cart_config(text, init):
    m = re.search(r"void balsente_state::" + re.escape(init) +
                  r"\(\)\s*\{\s*expand_roms\(([^)]*)\)", text)
    if not m:
        sys.exit(f"no expand_roms() call in {init}")
    consts = {"EXPAND_ALL": 0x00, "EXPAND_NONE": 0x3f, "SWAP_HALVES": 0x80}
    v = 0
    for tok in m.group(1).split("|"):
        tok = tok.strip()
        v |= consts[tok] if tok in consts else int(tok, 0)
    return v & 0x3f, bool(v & 0x80)


# ------------------------------------------------------------------ ROMs
def region_parts(game, region, size):
    """<part> elements for one region: every load at its offset, gaps 0x00."""
    text = driver_text()
    recs, unknown = region_records(blocks(text)[game], region)
    if unknown:
        sys.exit(f"{game} {region}: unparsed ROM records: {unknown}")
    pieces = []            # (dest, name, crc, file_offset, length)
    cur = None
    for rec in recs:
        kind, name, dest, length, crc = rec[:5]
        if kind == "load":
            cur = [name, crc, length]
            pieces.append((dest, name, crc, 0, length))
        elif kind == "continue":
            pieces.append((dest, cur[0], cur[1], cur[2], length))
            cur[2] += length
        elif kind == "reload":
            pieces.append((dest, cur[0], cur[1], 0, length))
        else:
            sys.exit(f"{game} {region}: record {kind} is not handled")
    pieces.sort()
    out, pos = [], 0
    for dest, name, crc, foff, length in pieces:
        if dest < pos:
            sys.exit(f"{game} {region}: overlapping loads at {dest:#x}")
        if dest > pos:
            out.append(f'<part repeat="{dest - pos:#x}">00</part>')
        attrs = f'name="{name}" crc="{crc:08x}"'
        whole = sum(1 for p in pieces if p[1] == name) == 1
        if not whole:
            attrs += f' offset="{foff:#x}" length="{length:#x}"'
        out.append(f"<part {attrs}/>")
        pos = dest + length
    if pos > size:
        sys.exit(f"{game} {region}: {pos:#x} bytes, more than {size:#x}")
    if pos < size:
        out.append(f'<part repeat="{size - pos:#x}">00</part>')
    return out, max(p[0] + p[4] for p in pieces)


# ---------------------------------------------------------------- inputs
def input_map(fields):
    """16 map bytes for IN0 and IN1, and the buttons the set uses."""
    m = {}
    used = {0: set(), 1: set()}
    starts = set()
    for tag, mask, dflt, tok in fields:
        if tag not in (":IN0", ":IN1"):
            continue
        port = 0 if tag == ":IN0" else 1
        for b in range(8):
            if not mask >> b & 1:
                continue
            key = (port, b)
            high = 0x40 if not dflt >> b & 1 else 0
            code = None
            j = re.fullmatch(r"P([12])_JOYSTICK(?:LEFT)?_(UP|DOWN|LEFT|RIGHT)", tok)
            bt = re.fullmatch(r"P([12])_BUTTON([1-4])", tok)
            if j:
                code = (0x20 if j.group(1) == "2" else 0) + JOY[j.group(2)] + high
            elif bt:
                pl = int(bt.group(1)) - 1
                code = pl * 0x20 + 3 + int(bt.group(2)) + high
                used[pl].add(int(bt.group(2)))
            elif tok in ("START1", "START2"):
                code = (0x20 if tok == "START2" else 0) + 8 + high
            elif tok in ("START3", "START4"):
                code = (12 if tok == "START3" else 13) + high
                starts.add(tok)
            elif tok in ("COIN1", "COIN2"):
                code = (0x20 if tok == "COIN2" else 0) + 9 + high
            elif tok == "SERVICE1":
                code = 10 + high
            elif tok == "DIPSWITCH":
                code = 0x80
            elif tok in ("UNUSED", "UNKNOWN", "TILT", "SPECIAL") or tok.startswith("TYPE_OTHER"):
                code = 0xfe if high else 0xff
            else:
                sys.exit(f"input {tag} bit {b}: token {tok} has no mapping")
            if key in m and m[key] != code:
                sys.exit(f"input {tag} bit {b}: two fields ({m[key]:#x}, {code:#x})")
            m[key] = code
    out = bytes(m.get((p, b), 0xff) for p in (0, 1) for b in range(8))
    return out, max(max(used[0], default=0), max(used[1], default=0)), sorted(starts)


# ------------------------------------------------------------------ DIPs
# Applied in turn to a DIP's option names until the line fits the OSD.
SHORTEN = [(" = ", "="), (" Coins", "C"), (" Coin", "C"), (" Credits", "Cr"), (" Credit", "Cr")]


def osd_name(s):
    return s.replace(",", "")


def dip_xml(machine):
    default = [0xff, 0xff, 0xff, 0xff, 0xfe]
    lines = []
    for sw in machine.findall("dipswitch"):
        tag, mask = ":" + sw.get("tag").lstrip(":"), int(sw.get("mask"))
        if tag not in DIP_BYTE:
            sys.exit(f"dipswitch {sw.get('name')} on unexpected port {tag}")
        byte = DIP_BYTE[tag]
        lo = (mask & -mask).bit_length() - 1
        hi = mask.bit_length() - 1
        if mask != ((1 << (hi + 1)) - (1 << lo)):
            sys.exit(f"dipswitch {sw.get('name')}: mask {mask:#x} is not contiguous")
        vals = {int(v.get("value")): v for v in sw.findall("dipvalue")}
        for v in vals.values():
            if v.get("default") == "yes":
                default[byte] = (default[byte] & ~mask) | int(v.get("value"))
        name = osd_name(sw.get("name"))
        if name.lower() == "unused":
            continue
        ids = [osd_name(vals[i << lo].get("name")) if (i << lo) in vals else "-"
               for i in range(1 << (hi - lo + 1))]
        width = 2 + len(name) + max(len(i) for i in ids)
        for a, b in SHORTEN:
            if width <= OSD_COLS:
                break
            ids = [i.replace(a, b) for i in ids]
            width = 2 + len(name) + max(len(i) for i in ids)
        if width > OSD_COLS:
            sys.exit(f"dip {name!r} is {width} columns, more than the OSD's {OSD_COLS}")
        bits = f"{byte * 8 + lo}" if lo == hi else f"{byte * 8 + lo},{byte * 8 + hi}"
        lines.append(f'<dip name="{name}" bits="{bits}" ids="{",".join(ids)}"/>')
    lines.append('<dip name="Flip Screen" bits="32" ids="Off,On"/>')
    return default, lines


# ------------------------------------------------------------------ .mra
def xml_escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def build(game, refresh):
    text = driver_text()
    g = game_line(text, game)
    _, machine = listxml(game, refresh)
    fields = ports(game, refresh)

    cdmask, swap = cart_config(text, g["init"])
    prg, prg_len = region_parts(game, "maincpu", PRG_SIZE)
    gfx, _ = region_parts(game, "gfx1", GFX_SIZE)
    banks16 = prg_len > 0x20000

    imap, nbuttons, starts = input_map(fields)
    an = analog_bytes(analog_ports(text, g["inp"]))
    cfg = bytes([cdmask, (1 if swap else 0) | (2 if banks16 else 0), *an,
                 adc_config(text, g["init"])]) + bytes(9) + imap
    default, dips = dip_xml(machine)

    names = BUTTON_NAMES.get(game) or BUTTON_NAMES.get(g["parent"] or "") or \
        [f"Button {i + 1}" for i in range(nbuttons)]
    names = list(names) + ["-"] * (4 - len(names))
    extra = "".join(",Start " + t[-1] for t in starts)
    zips = "|".join([f"{game}.zip"] + ([f"{g['parent']}.zip"] if g["parent"] else []) + [SND_ZIP])
    rot = {"ROT0": "horizontal", "ROT90": "vertical (cw)", "ROT270": "vertical (ccw)"}[g["rot"]]
    analog = [p for p in analog_ports(text, g["inp"]) if p]
    players = machine.find("input").get("players") if machine.find("input") is not None else "1"

    ind = "\t\t"
    body = "\n".join(ind + p for p in prg + gfx)
    cfg_hex = " ".join(f"{b:02X}" for b in cfg)
    note = ("\n\t<!-- Analog: " + ", ".join(
        f"P{p + 1} {k.lower()}{' reversed' if r else ''}" for k, p, r, _ in analog) +
        ". Player 1's from the mouse or the left stick, others from their stick. -->"
        if analog else "")
    x = f"""<misterromdescription>
	<about author="Paul Priest" webpage="https://github.com/ppriest/Arcade-BallySente_MiSTer" source="MAME balsente.cpp"/>
	<name>{xml_escape(g['title'])}</name>
	<setname>{game}</setname>
	<rbf>BallySente</rbf>
	<mameversion>0289</mameversion>
	<year>{g['year']}</year>
	<manufacturer>{xml_escape(g['maker'])}</manufacturer>
	<rotation>{rot}</rotation>
	<players>{players}</players>{note}

	<!-- Layout and configuration bytes: scripts/build_mra.py, rtl/balsente_core.sv. -->
	<rom index="0" zip="{zips}" md5="none">
{body}
		<part name="{SND_ROM}" crc="{SND_CRC}"/>
		<part>{cfg_hex}</part>
	</rom>

	<nvram index="4" size="512"/>

	<buttons names="{','.join(names)},Start,Coin,Service,Pause{extra}" default="A,B,X,Y,Start,Select,L,R"/>

	<switches default="{','.join(f'{b:02X}' for b in default)}">
{chr(10).join(ind + d for d in dips)}
	</switches>
</misterromdescription>
"""
    return g, x, cfg


def fname(title):
    return re.sub(r'[<>:"/\\|?*]', "-", title) + ".mra"


def check_image(game, path, cfg, parent=None):
    """The image the .mra describes must be the regions build_region.py makes."""
    from build_region import build as region
    own = [f"{game}.zip"] + ([f"{parent}.zip"] if parent else [])
    zips = []
    for z in own + [SND_ZIP]:
        for d in rom_dirs():
            if (d / z).exists():
                zips.append(str(d / z))
                break
    img = mra.build_image(str(path), zips, IMAGE_SIZE)
    prg = region(game, "maincpu", zips=own)
    want = prg + bytes(PRG_SIZE - len(prg)) + region(game, "gfx1", zips=own)
    with zipfile.ZipFile(zips[-1]) as z:
        want += z.read(SND_ROM)
    want += cfg
    if img != want:
        i = next(k for k in range(len(want)) if img[k] != want[k])
        sys.exit(f"{path.name}: image differs from build_region.py at {i:#x}")
    return img


def rom_dirs():
    from build_region import rom_zips
    return rom_zips()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sets", nargs="*", default=RUNNABLE)
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--image", action="store_true",
                    help="also write debug/rom/<set>_image.hex for sim/board_tb")
    a = ap.parse_args()
    for game in a.sets:
        g, x, cfg = build(game, a.refresh)
        path = out_dir(game, g["parent"]) / fname(g["title"])
        path.parent.mkdir(parents=True, exist_ok=True)
        # A set that changed folder leaves no copy behind.
        for old in OUT.rglob(path.name):
            if old != path:
                old.unlink()
        path.write_text(x, encoding="utf-8", newline="\n")
        img = check_image(game, path, cfg, g["parent"])
        if a.image:
            hexp = REPO / "debug" / "rom" / f"{game}_image.hex"
            hexp.write_text("\n".join(f"{b:02x}" for b in img) + "\n")
        print(f"{game:10s} -> {path.relative_to(REPO).as_posix()}  cdmask {cfg[0]:02x} flags {cfg[1]:02x}  "
              f"map {cfg[16:].hex()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
