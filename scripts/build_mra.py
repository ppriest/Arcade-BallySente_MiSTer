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
               1      bit 0 SWAP_HALVES, bit 1 a 256 KB maincpu region, bit 2 the
                      second ROM bank at 0x9F00 (the st1002 and spiker boards)
               2-5    AN0-AN3 descriptors (rtl/analog_inputs.sv)
               6      ADC: bits 1:0 the shift, bit 7 raw (rtl/adc.sv)
               7      board variant (rtl/main_bus.sv): 1 teamht, 2 grudge,
                      3 spiker, 4 rescraid, 5 the gun (nstocker)
               8, 9   IN0, IN1 bits that toggle on each press (PORT_TOGGLE)
               10-15  0
               16-23  IN0 bits 0-7, one map byte each
               24-31  IN1 bits 0-7 (bit 7 is VBLANK, from the board)

A map byte says where a port bit comes from:
    0x00-0x1f   joystick_0 bit n, active low as MAME's ports are
    0x20-0x3f   joystick_1 bit n
    +0x40       active high instead
    0x80        a DIP: the same bit of <switches> byte 2 (IN0) or 3 (IN1)
    0xa0-0xbf   joystick_2 bit n, active low
    0xc0-0xdf   joystick_3 bit n, active low
    0xfe / 0xff constant 0 / 1

Joystick bits are the core's CONF_STR J1 line: 0 R, 1 L, 2 D, 3 U, 4-7
buttons 1-4, 8 Start, 9 Coin, 10 Service, 11 Pause, 12 Start 3, 13 Start 4
(on player 1's controller: those sets pick the player count on one panel),
14-17 the right stick R, L, D, U (rescraid). A set with third and fourth
players' controls (teamht, grudge) takes theirs from joysticks 2 and 3.
<switches> bytes are SWH (0x9900), SWG (0x9901), the DIP bits of IN0 and IN1.
Bit 24 (IN1 bit 0, a DIP on no set) is the fake Flip Screen DIP
(BallySente.sv), since no set has a flip of its own. It cannot go above bit 31:
Main_MiSTer builds the default with `binary[i] << (i * 8)` on an int
(support/arcade/mra_loader.cpp), so byte 3's top bit sign-extends over bits
32-63 and a fifth byte is shifted out.
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

# Every set the RTL runs. Left out: triviaes4/5 (other hardware).
RUNNABLE = PHASE2 + ["otwalls", "snakepit", "snakepita", "snakjack", "stocker",
                     "triviag1", "triviag1a", "triviabb", "triviag2", "triviayp",
                     "triviasp", "triviaes", "triviaes2", "gimeabrk", "minigolf",
                     "minigolfa", "minigolfb", "minigolfct", "sfootbal", "nametune",
                     "nametunea", "teamht", "grudge", "grudgei", "grudgep", "spiker",
                     "spikera", "spikerb", "rescraid", "rescraida", "stompin", "stompina",
                     "nstocker", "nstockera", "shrike"]

ANALOG_KIND = {"TRACKBALL_X": 1, "TRACKBALL_Y": 2, "DIAL": 3, "AD_STICK_X": 4,
               "AD_STICK_Y": 5, "PADS": 6}

# Configuration byte 7, the board variant (rtl/main_bus.sv), by MACHINE_CONFIG;
# 5, the light gun, comes from config_shooter_adc(true, ...) instead.
VARIANT = {"teamht": 1, "grudge": 2, "spiker": 3, "rescraid": 4, "shrike": 6}

PRG_SIZE, GFX_SIZE, SND_SIZE = 0x40000, 0x10000, 0x2000
GFX_BASE, SND_BASE, CFG_BASE = 0x40000, 0x50000, 0x52000
IMAGE_SIZE = CFG_BASE + 32

SND_ZIP, SND_ROM, SND_CRC = "sente6vb.zip", "8002-10 9-25-84.5", "4dd0a525"

DIP_BYTE = {":SWH": 0, ":SWG": 1, ":IN0": 2, ":IN1": 3}
J1 = "J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Service,Pause,Start 3,Start 4,R Right,R Left,R Down,R Up"
JOY = {"RIGHT": 0, "LEFT": 1, "DOWN": 2, "UP": 3}
# Joystick bits past Pause, as CONF_STR's J1 line names them
EXTRA_BITS = {12: "Start 3", 13: "Start 4", 14: "R Right", 15: "R Left", 16: "R Down", 17: "R Up"}
OSD_COLS = 28

# The game's own names for its buttons, keyed by set; a clone takes its
# parent's. Entry N names MAME's BUTTON(N+1), so keep the order and count; an
# empty list or a missing set keeps "Button N".
BUTTON_NAMES = {
    "cshift":   ["Blue", "Red"],                            # Chicken Shift
    "snakjack": ["Sneeze"],                                 # Snacks'n Jaxson
    "hattrick": ["Shoot"],                                  # Hat Trick
    "toggle":   ["Shoot"],                                  # Toggle
    "gghost":   ["Jump", "Button 2"],                       # Goalie Ghost
    "otwalls":  [],                                         # Off the Wall (dials only)
    "snakepit": ["Whip"],                                   # Snake Pit
    "stocker":  ["Gas"],                                    # Stocker
    "triviag1": ["Green", "Red"],                           # Trivial Pursuit (Genus)
    "triviabb": ["Green", "Red"],                           # Trivial Pursuit (Baby Boomer)
    "triviag2": ["Green", "Red"],                           # Trivial Pursuit (Genus II)
    "triviayp": ["Green", "Red"],                           # Trivial Pursuit (Young Players)
    "triviasp": ["Green", "Red"],                           # Trivial Pursuit (All Star Sports)
    "triviaes": ["Green", "Red"],                           # Trivial Pursuit (Spanish)
    "gimeabrk": ["Position Cue Ball"],                      # Gimme A Break
    "minigolf": ["Tee Select"],                             # Mini Golf
    "sfootbal": ["Pass/Player"],                            # Street Football
    "nametune": ["1", "2", "3", "4"],                       # Name That Tune
    "teamht":   ["Shoot"],                                  # Team Hat Trick
    "grudge":   ["Button 1"],                               # Grudge Match
    "spiker":   ["Jump/Spike"],                             # Spiker
    "rescraid": ["Select Weapons"],                         # Rescue Raider (plus the right stick)
    "stompin":  ["Zapper"],                                 # Stompin' (the pads are the d-pad)
    "nstocker": ["Trigger"],                                # Night Stocker (the trigger)
    "sentetst": ["Button 1"],                               # Sente Diagnostic Cartridge
}

OUT = REPO / "releases"
CACHE = REPO / "debug" / "mame"


def out_dir(game, parent):
    """Parents in releases/, clones in releases/_alternatives/_<parent>/, as
    the MRA documentation and MRA-Alternatives lay them out; the folder is the
    parent's title without its parenthesised qualifiers ("Mini Golf (set 1)"
    -> `_Mini Golf`), as the Fuuki core names it."""
    if not parent:
        return OUT
    base = game_line(driver_text(), parent)["title"].split(" (")[0]
    return OUT / "_alternatives" / ("_" + fname(base)[:-4])


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
    lines = path.read_text().splitlines()
    if not refresh and lines and len(lines[0].split("\t")) < 7:
        return ports(game, True)      # dumped before ports.lua wrote the toggle column
    out = set()
    for ln in lines:
        f = ln.split("\t")
        out.add((f[0], int(f[1]), int(f[2]), f[3] + ("/toggle" if f[6] == "toggle" else "")))
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
            # Stompin: buttons in the analog ports' top bits, one pad row each
            if re.search(r"IPT_BUTTON\d", ln) and "PORT_BIT" in ln:
                ports_[cur] = ("PADS", int(cur[2]), False, False)
                continue
            k = re.search(r"IPT_(\w+)", ln)
            if k and "PORT_BIT" in ln and not (k.group(1) == "UNUSED" and
                                               ports_.get(cur) and ports_[cur][0] == "PADS"):
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
    bit 7 raw for MAME's shift of 32; and whether the set has the gun."""
    m = re.search(r"void balsente_state::" + re.escape(init) +
                  r"\(\)\s*\{[^}]*config_shooter_adc\(\s*(true|false)\s*,\s*(\d+)", text)
    if not m:
        return 0, False
    shift = int(m.group(2))
    return (0x80 if shift == 32 else shift), m.group(1) == "true"


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
def region_size(game, region):
    """The ROM_REGION's declared size."""
    m = re.search(r'ROM_REGION\(\s*(0x[0-9a-fA-F]+)\s*,\s*"' + region + '"',
                  blocks(driver_text())[game])
    return int(m.group(1), 16)


def gfx_parts(game):
    """The sprite region, repeated to fill 64 KB when it is smaller: MAME masks
    sprite addresses with the region's size (balsente_v.cpp m_sprite_mask), so
    a 32 KB region mirrors."""
    size = region_size(game, "gfx1")
    parts, _ = region_parts(game, "gfx1", min(size, GFX_SIZE))
    # A 128 KB region (Shrike Avenger) is two banks; the upper one goes in the
    # program region's free half (shrike_parts()).
    return parts * max(1, GFX_SIZE // size)


# Shrike Avenger: its 128 KB program leaves the upper half of the 256 KB
# program region free, and the second 64 KB of sprites goes there (read by the
# core's second program-ROM port); its 68000 program follows the configuration.
SHRIKE_SPR_HI = 0x20000
M68K_BASE, M68K_SIZE = 0x54000, 0x4000


def shrike_prg_parts(game):
    lo, _ = region_parts(game, "maincpu", SHRIKE_SPR_HI)
    hi, _ = region_parts(game, "gfx1", GFX_SIZE, lo=GFX_SIZE)
    return lo + hi + [f'<part repeat="{PRG_SIZE - SHRIKE_SPR_HI - GFX_SIZE:#x}">00</part>']


def m68k_parts(game):
    """The 68000's two ROM_LOAD16_BYTE halves, even (high) bytes first, whole."""
    recs, unknown = region_records(blocks(driver_text())[game], "68k")
    if unknown or any(r[0] != "load16_byte" for r in recs) or len(recs) != 2:
        sys.exit(f"{game} 68k: expected two ROM_LOAD16_BYTE records: {recs} {unknown}")
    recs = sorted(recs, key=lambda r: r[2] & 1)
    return [f'<part name="{r[1]}" crc="{r[4]:08x}"/>' for r in recs]


def region_parts(game, region, size, lo=0):
    """<part> elements for one region, or for its window [lo, lo + size):
    every load at its offset, gaps 0x00."""
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
    # A later load overwrites an earlier one where they overlap, as MAME loads
    # them in order: grudgei's GM-6A replaces the last 8 KB of GM-2A, and
    # grudge's CD12 all of CD4 (the same data). An earlier piece is cut to what
    # is left of it.
    kept = []
    for p in pieces:
        plo, phi = p[0], p[0] + p[4]
        nxt = []
        for q in kept:
            qlo, qhi = q[0], q[0] + q[4]
            if qhi <= plo or qlo >= phi:
                nxt.append(q)
                continue
            if qlo < plo:
                nxt.append((qlo, q[1], q[2], q[3], plo - qlo))
            if qhi > phi:
                nxt.append((phi, q[1], q[2], q[3] + (phi - qlo), qhi - phi))
        kept = nxt + [p]
    loadlen = {q[1]: q[4] for q in pieces if q[3] == 0}
    win = []
    for dest, name, crc, foff, length in kept:
        a, b = max(dest, lo), min(dest + length, lo + size)
        if a < b:
            win.append((a - lo, name, crc, foff + (a - dest), b - a))
    pieces = sorted(win)
    out, pos = [], 0
    for dest, name, crc, foff, length in pieces:
        if dest < pos:
            sys.exit(f"{game} {region}: overlapping loads at {dest:#x}")
        if dest > pos:
            out.append(f'<part repeat="{dest - pos:#x}">00</part>')
        attrs = f'name="{name}" crc="{crc:08x}"'
        whole = (sum(1 for p in pieces if p[1] == name) == 1 and foff == 0
                 and length == loadlen.get(name))
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
def input_map(fields, seats=False):
    """16 map bytes for IN0 and IN1, the number of buttons the set uses, and
    which joystick bits past Pause (EXTRA_BITS) it uses."""
    m = {}
    used = {0: set(), 1: set()}
    extras = set()
    toks = {tok for tag, _, _, tok in fields if tag in (":IN0", ":IN1")}
    # A set with a third player's controls has its own Start and Coin for them;
    # otherwise START3/4 are the player-count buttons on player 1's controller.
    three = any(t.startswith(("P3_", "P4_")) or t == "COIN3" for t in toks)
    # Shrike Avenger's cabinet has two seat buttons the game wants pressed
    # together (misteraddons' notes; MAME's START1 and START2): both are Start.
    toggle = [0, 0]
    for tag, mask, dflt, tok in fields:
        if tag not in (":IN0", ":IN1"):
            continue
        port = 0 if tag == ":IN0" else 1
        # PORT_TOGGLE (Stocker's gear): a press flips the bit (rtl/balsente_core.sv).
        # MAME marks every DIP switch a toggle too; those are not inputs here.
        if tok.endswith("/toggle"):
            tok = tok[:-len("/toggle")]
            if tok != "DIPSWITCH":
                toggle[port] |= mask
        for b in range(8):
            if not mask >> b & 1:
                continue
            key = (port, b)
            high = 0x40 if not dflt >> b & 1 else 0
            code = None
            j = re.fullmatch(r"P([1-4])_JOYSTICK(?:LEFT)?_(UP|DOWN|LEFT|RIGHT)", tok)
            jr = re.fullmatch(r"P1_JOYSTICKRIGHT_(UP|DOWN|LEFT|RIGHT)", tok)
            bt = re.fullmatch(r"P([1-4])_BUTTON([1-4])", tok)
            st = re.fullmatch(r"(START|COIN)([1-4])", tok)
            if j:
                code = player_code(int(j.group(1)), JOY[j.group(2)], high, tok)
            elif jr:
                code = 14 + JOY[jr.group(1)] + high
                extras.add(14 + JOY[jr.group(1)])
            elif bt:
                pl = int(bt.group(1))
                code = player_code(pl, 3 + int(bt.group(2)), high, tok)
                if pl <= 2:
                    used[pl - 1].add(int(bt.group(2)))
            elif seats and tok == "START2":
                code = 8 + high
            elif tok == "P1_BUTTON5":
                code = 0xfe if high else 0xff      # Shrike's carpet switch, left released
            elif st and (three or st.group(2) in "12"):
                code = player_code(int(st.group(2)), 8 if st.group(1) == "START" else 9, high, tok)
            elif tok in ("START3", "START4"):
                code = (12 if tok == "START3" else 13) + high
                extras.add(12 if tok == "START3" else 13)
            elif tok == "SERVICE1":
                code = 10 + high
            elif tok == "DIPSWITCH":
                code = 0x80
            elif tok == "CUSTOM":
                code = 0xff          # Night Stocker's gun bits: rtl/game_board.sv
            elif tok in ("UNUSED", "UNKNOWN", "TILT", "SPECIAL") or tok.startswith("TYPE_OTHER"):
                code = 0xfe if high else 0xff
            else:
                sys.exit(f"input {tag} bit {b}: token {tok} has no mapping")
            if key in m and m[key] != code:
                sys.exit(f"input {tag} bit {b}: two fields ({m[key]:#x}, {code:#x})")
            m[key] = code
    out = bytes(m.get((p, b), 0xff) for p in (0, 1) for b in range(8))
    return out, max(max(used[0], default=0), max(used[1], default=0)), extras, toggle


def player_code(pl, bit, high, tok):
    """Map byte for joystick bit `bit` of player `pl` (1-4)."""
    if pl <= 2:
        return (0x20 if pl == 2 else 0) + bit + high
    if high:
        sys.exit(f"{tok}: an active-high input for player {pl} has no encoding")
    return (0xa0 if pl == 3 else 0xc0) + bit


# ------------------------------------------------------------------ DIPs
# Applied in turn to a DIP's option names until the line fits the OSD.
SHORTEN = [(" = ", "="), (" Coins", "C"), (" Coin", "C"), (" Credits", "Cr"), (" Credit", "Cr")]


def osd_name(s):
    return s.replace(",", "")


FLIP_BIT = 24


def dip_xml(machine):
    default = [0xff, 0xff, 0xff, 0xff]
    lines = []
    for sw in machine.findall("dipswitch"):
        tag, mask = ":" + sw.get("tag").lstrip(":"), int(sw.get("mask"))
        if tag not in DIP_BYTE:
            sys.exit(f"dipswitch {sw.get('name')} on unexpected port {tag}")
        byte = DIP_BYTE[tag]
        if byte == FLIP_BIT // 8 and mask >> (FLIP_BIT % 8) & 1:
            sys.exit(f"dipswitch {sw.get('name')} is on the fake Flip Screen's bit {FLIP_BIT}")
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
    default[FLIP_BIT // 8] &= ~(1 << FLIP_BIT % 8)
    lines.append(f'<dip name="Flip Screen" bits="{FLIP_BIT}" ids="Off,On"/>')
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
    shrike = region_size(game, "gfx1") > GFX_SIZE
    if shrike:
        prg, prg_len = shrike_prg_parts(game), SHRIKE_SPR_HI
    else:
        prg, prg_len = region_parts(game, "maincpu", PRG_SIZE)
    gfx = gfx_parts(game)
    banks16 = prg_len > 0x20000

    imap, nbuttons, extras, toggle = input_map(fields, seats=shrike)
    adc, shooter = adc_config(text, g["init"])
    if shrike:
        adc |= 0x40      # the stick's raw ports are 0x80-centred (rtl/adc.sv)
    variant = 5 if shooter else VARIANT.get(g["machine"], 0)
    aports = analog_ports(text, g["inp"])
    if variant == 2:
        # Grudge Match's dials are read through the steering register
        # (grudge_wheels.sv), not the ADC.
        aports = [None] * 4
    nomouse = [False] * 4
    if variant == 5:
        # Night Stocker's dial is player 2's in MAME only to keep it off the
        # crosshair's controls; here it is player 1's, without the mouse.
        for i, p in enumerate(aports):
            if p and p[0] == "DIAL":
                aports[i] = (p[0], 0, p[2], p[3])
                nomouse[i] = True
    an = [b | (4 if nm else 0) for b, nm in zip(analog_bytes(aports), nomouse)]
    bank2 = g["machine"] in ("st1002", "spiker")
    cfg = bytes([cdmask, (1 if swap else 0) | (2 if banks16 else 0) | (4 if bank2 else 0), *an, adc,
                 variant, *toggle]) + bytes(6) + imap
    default, dips = dip_xml(machine)

    names = BUTTON_NAMES.get(game) or BUTTON_NAMES.get(g["parent"] or "") or \
        [f"Button {i + 1}" for i in range(nbuttons)]
    names = list(names) + ["-"] * (4 - len(names))
    # Joystick bits past Pause (11) that the set uses, named in CONF_STR's order
    top = max(extras, default=11)
    extra = "".join("," + (EXTRA_BITS[b] if b in extras else "-") for b in range(12, top + 1))
    zips = "|".join([f"{game}.zip"] + ([f"{g['parent']}.zip"] if g["parent"] else []) + [SND_ZIP])
    rot = {"ROT0": "horizontal", "ROT90": "vertical (cw)", "ROT270": "vertical (ccw)"}[g["rot"]]
    analog = [p for p in aports if p]
    players = machine.find("input").get("players") if machine.find("input") is not None else "1"

    ind = "\t\t"
    m68k = "".join(f"\n{ind}" + q for q in
                   ([f'<part repeat="{M68K_BASE - IMAGE_SIZE:#x}">00</part>'] + m68k_parts(game)
                    if shrike else []))
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
		<part>{cfg_hex}</part>{m68k}
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
    prg = region(game, "maincpu", zips=own)
    gfx = bytes(region(game, "gfx1", zips=own))
    shrike = len(gfx) > GFX_SIZE
    img = mra.build_image(str(path), zips, M68K_BASE + M68K_SIZE if shrike else IMAGE_SIZE)
    if shrike:
        want = (bytes(prg) + gfx[GFX_SIZE:] + bytes(PRG_SIZE - len(prg) - GFX_SIZE)
                + gfx[:GFX_SIZE])
    else:
        want = prg + bytes(PRG_SIZE - len(prg)) + gfx * max(1, GFX_SIZE // len(gfx))
    with zipfile.ZipFile(zips[-1]) as z:
        want += z.read(SND_ROM)
    want += cfg
    if shrike:
        # the two ROM_LOAD16_BYTE files whole, even (high) bytes first
        recs = sorted(region_records(blocks(driver_text())[game], "68k")[0], key=lambda r: r[2] & 1)
        zs = [zipfile.ZipFile(z) for z in zips]
        want += bytes(M68K_BASE - IMAGE_SIZE) + b"".join(
            mra._zip_read(zs, r[1], r[4]) for r in recs)
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
