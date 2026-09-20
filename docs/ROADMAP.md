# Bally/Sente SAC-I — MiSTer Core Roadmap

**Approved. A phase whose scope changes goes back for approval.**

## Context

Goal: a DE10-nano MiSTer core for the Bally/Sente SAC-I cartridge platform, emulated by MAME's
`bally/balsente.cpp` and the devices it instantiates — a Quartus 17.0.2 Verilog/SystemVerilog
project producing one `.rbf` and a `.mra` per supported set, reusing proven open components where
they exist.

**What sets the shape of this project: the digital logic is small and the analog sound is the
whole risk.** The SAC-I motherboard is 1984 TTL around a 1.25 MHz 6809 — no custom ASICs, no
tilemap chip, no protection MCU, a 408 KB worst-case ROM set. Against that, the 6VB audio board
carries six **CEM3394** chips: complete analog synthesiser voices driven by control voltages from
a 12-bit DAC, with no digital register interface and no FPGA precedent anywhere.

> **Revised after reading the model** (see `HARDWARE_NOTES.md`, "What MAME's model actually is").
> This roadmap was drafted on the driver's "CEM3394 emulation is not perfect" note. That note was
> last touched 2026-05-24; MAME rebuilt the device onto its virtual-analog primitives
> (`va_vco`, `va_lpf4`, `va_vca`, `filter_rc`) afterwards, in June and July 2026. The reference is
> a structured, portable signal chain — a polyBLEP oscillator into a Zavalishin TPT ladder filter
> into an RC high-pass into a VCA — costing roughly 20 multiplies per voice per sample, about
> 12 M multiplies/s for all six at 96 kHz. **The arithmetic is comfortable and the specification
> is good.** The risk is narrower than stated below: whether a fixed-point port stays stable at
> high resonance and converges the board's own calibration loop. Phase 0 criterion 5 is unchanged
> and still the gate; both questions have since been answered yes.

Genuinely new work, in order of risk:

1. **Six CEM3394 voices** — VCO (tri/saw/pulse + PWM), mixer with external noise input, resonant
   4-pole VCF, VCA, all controlled by eight exponential-law control voltages per chip. Ported from
   MAME's virtual-analog chain; no silicon ground truth, but a structured reference.
2. **The 6VB self-calibration loop** — the sound program measures a voice's oscillator through
   8253 counter 0. It must work against the RTL voice, not against a faked frequency.
3. **Video** — a 256×240 4bpp packed bitmap the CPU draws into, plus a 40-entry sprite overlay
   whose pixels are the *high nibble of a palette index*, not a colour. Small, but the palette
   bank changes mid-frame.
4. **Cartridge address mapping** — `expand_roms` bank tables as a per-game `.mra` config byte.
5. **Peripherals** — light gun (Night Stocker), trackball, steering (Stocker, Grudge Match),
   32-pad mat (Stompin'), and two X2212 NOVRAMs that must persist.

Everything else is a port with verification: MC6809E, Z80, 68000, 8253, 6850, an LFSR.

Cross-cutting findings from the previous cores are in **[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**.
Working practice built on them is in **[`WORKFLOW.md`](WORKFLOW.md)**. The entries that already
bind decisions here are collected under "Pitfalls that already bind decisions here".

## Progress

**Phase 0: all 5 criteria met.** Both halves of the CEM3394 voice are in RTL and bit-exact against the model, and the board's own self-calibration runs on T80 out of the real audio ROM and takes MAME's search path step for step.

| # | Criterion | State |
|---|---|---|
| 1 | Vendored modules pass their own tests on arrival | **Met by substitute.** Neither vendored CPU has an upstream testbench: `mc6809i` was validated against real hardware and T80 ships none, so the criterion is unmeetable as written. The substitute, recorded in each `PROVENANCE.md`, is a MAME bus-trace diff, and both now pass. `mc6809i`: 400,000 cycles, all 52,232 writes identical, differences only in what a dead cycle drives. **T80: 60,000 cycles, 0 differences — byte-identical to MAME, reads included** (`sim/sound_cpu_tb`, ModelSim, the 6VB's own 8 KB ROM). |
| 2 | The CPU boots the first target and matches MAME's bus trace | **Met.** 400,000 bus cycles of `sentetst` from reset; all 52,232 writes identical in address, lanes, data and order. 12,171 cycles (3.04%) differ and every one is a non-VMA or prefetch address choice — zero functional differences, recorded in `docs/MAME_KLUDGES.md`. Evidence: `scripts/compare_boot_trace.py compare sentetst`, `scripts/classify_trace_diff.py sentetst`, `debug/sentetst-boot/classify.txt`. |
| 3 | Measured CPI on real game code | **Met.** 4.207 bus cycles per opcode fetch over those 400,000 cycles; 22.5% of cycles are dead ($FFFF). Memory stall is zero by construction in this bench — every answer is same-cycle — so the split is 100% execution. SDRAM stalls are a Phase 2 measurement. |
| 4 | Standalone Fmax and area for the CPU | **Met.** `rtl/cpu/synth_check`, Quartus 17.0.2, 5CSEBA6U23I7. **1,472 ALMs (4%)**, 367 registers, no BRAM, no DSP. Timing at 40 MHz `clk_sys`: worst setup slack **+12.389 ns**, hold +0.389 ns, TNS 0 on every corner. **Fmax 79.3 MHz** with the `cen_E` multicycle the design actually has, and **51.78 MHz** with every exception removed — so the core closes 40 MHz with 29% headroom even on the pessimistic reading. |
| 5 | A CEM3394 voice reproduces MAME's model, and the 6VB calibration loop converges against it | **Met.** The software model is written and ported line by line from MAME (`scripts/cem3394_model.py`); the CV laws reproduce the datasheet to 7×10⁻⁷ and pitch through the whole chain tracks to 10⁻⁴ at every frequency the board calibrates at. Fixed point is stable at all 60 operating points in every format from 22 to 34 bits, including past the self-oscillation threshold — the word width buys noise floor only. Full evidence and the format choice in [`CEM3394_SPIKE.md`](CEM3394_SPIKE.md). The model is also anchored to MAME's own audio under two stimuli: the 6VB boot/calibration sequence (level +0.00 dB, worst octave 0.01 dB against a 1.28 dB control, waveform −27.2 dB) and real game audio after a coin is inserted (level +0.00 dB, worst octave 0.28 dB against a 17.19 dB control, envelope correlation +0.974, waveform −4.6 dB and degrading across the window — accumulating phase drift, not a wrong transfer function). The **ladder filter now exists in RTL** (`rtl/sound/cem3394_lpf4.sv` + `tanh_lut.sv`), is bit-exact against the model over 38,400 samples at 20 operating points with zero mismatches, and closes timing: 827 ALMs, 5 DSP, 6 RAM blocks, +7.985 ns worst slack, Fmax 61.12 MHz. The **oscillator is now in RTL too** (`cem3394_vco.sv` + `vco_blep.sv` + `vco_blamp.sv`), bit-exact over 11,520 samples at 6 settings, 1,099 ALMs, 33 DSP, +9.468 ns slack, and 8 cycles a sample on a musical mix against a worst case of 60. **The calibration loop now closes.** `rtl/sound/pit8253.sv` and `rtl/sound/sente6vb_io.sv` are written, and `sim/calib_tb` runs T80 out of the audio board's real 8 KB ROM against them. Over 249 measurements every reading matches `0xFFFF - round(count0 * 2e6 / f)`; compared against MAME's own I/O trace across 168 measurements, **the voice chosen, the vco/filter mode, the control voltage and counter 0's count are identical on every one** — the board's binary search takes MAME's path, step for step — and 58 readings differ by exactly one count of 65,535, which is where the flip-flop fires against the 2 MHz grid and is a difference MAME shows against itself. **Still open:** one game only for the in-game audio check, and the control-voltage to frequency map, still evaluated in the bench rather than as the lookup table the core needs. The six-voice cycle budget is now settled and does **not** disturb the single-clock design: three voices on each of two shared pipelines is a bounded worst case of 303 of the 417 cycles a 96 kHz sample has at 40 MHz, measured sample by sample with all six voices at the top of the oscillator's range (`docs/HACKS.md`). 48 kHz, which would let one pipeline fit, costs −17.9 dBFS: the filter self-oscillates above 24 kHz and cannot be represented there. |

Research is complete: `docs/HARDWARE_NOTES.md` is written from `bally/balsente.cpp` (3064 lines),
`balsente_m.cpp`, `balsente_v.cpp`, `sente6vb.cpp`, `devices/sound/cem3394.cpp` and the `va_*`
primitives at MAME commit `5ae594ba`. 41 sets enumerated, 39 in scope. The reuse survey below
located an RTL source for every digital part and none for the CEM3394.

Incidental result worth keeping: `sentetst` is an even better first target than expected — its
whole program is one 8 KB ROM in the fixed EF window (`ROM_START` loads a single file at
0x1e000), so booting it exercises no cartridge banking at all.

## Game scope

39 sets on SAC-I hardware across seven machine configurations. All `ROT0`,
`MACHINE_SUPPORTS_SAVE`; none is marked `MACHINE_NOT_WORKING`.

| Config | Sets | Difference | maincpu | gfx1 |
|---|---|---|---|---|
| `balsente` | sentetst, cshift, hattrick, gghost, otwalls, snakepit(a), triviag1(a), snakjack, stocker, triviabb, triviag2, triviayp, triviasp, gimeabrk, minigolf(a,b,ct), stompina, triviaes(2), toggle | — | 0x20000 | 0x10000 |
| `teamht` | teamht | input multiplexer at 0x9000, extra read 0x9404 | 0x20000 | 0x10000 |
| `grudge` | grudge, grudgei, grudgep | three steering wheels at 0x9400 | 0x20000 | 0x10000 |
| `st1002` | nstocker(a), sfootbal, stompin, nametune(a) | second bank register at 0x9f00 | 0x20000, **0x40000** for nametune | 0x10000 |
| `spiker` | spiker, spikera, spikerb | `st1002` + pixel-expand helper at 0x9f80 | 0x20000 | 0x10000 |
| `rescraid` | rescraid, rescraida | non-cartridge; one 8-bit NOVRAM | 0x20000 | 0x10000 |
| `shrike` | shrike | adds a 68000 @ 8 MHz + shared RAM at 0x9e00 | 0x20000 | **0x20000** |

### Scope decision

- **In scope:** all 39 SAC-I sets — one memory map, one screen, one chipset, 408 KB worst case.
  The differences are bank tables, an input multiplexer and analog controls, all `.mra`
  configuration.
- **Out of the first scope:** `triviaes4`, `triviaes5` — different Maibesa hardware (MC6845 CRTC,
  Z80 + 2×AY8910 + MSM5205 sound board), and MAME marks both `MACHINE_NOT_WORKING`. Two
  independent reasons; they would be a separate core.
- **Out of the first scope:** `shrike` — needs a whole second CPU, and MAME's own note is
  "Shrike Avenger doesn't work properly" with the 68000 motion-base side returning a canned
  status. Deferred to Phase 4, not dropped.
- **First-target set:** **`sentetst`, the Sente Diagnostic Cartridge.** It is the board's own
  self-test: it exercises RAM, ROM banks, the video bitmap, the palette, the ADC, the random
  generator, the NOVRAM and the sound link, and reports pass/fail on screen. `EXPAND_ALL`
  banking, no analog controls. Final choice is a Phase 0 decision, made on which boots furthest,
  measured.
- **Second target:** **`cshift`** (Chicken Shift) — `EXPAND_ALL`, no analog, a real game;
  then **`otwalls`** for the trackball path.

## Hardware reality (from the driver, not assumption)

### Chips

| Chip | Where | Role |
|---|---|---|
| MC6809E | `balsente.cpp:1378` | main CPU, 1.25 MHz |
| Z80 | `sente6vb.cpp:107` | 6VB sound CPU, 4 MHz |
| 68000 | `balsente.cpp:1455` | `shrike` only, 8 MHz |
| 6850 ACIA ×2 | `balsente.cpp:1382`, `sente6vb.cpp:111` | serial link between the boards |
| 8253 PIT | `sente6vb.cpp:123` | sound timing + oscillator measurement |
| CEM3394 ×6 | `sente6vb.cpp:151` | analog synthesiser voices |
| MM5837 | `sente6vb.cpp:130` | noise source into every voice's external input |
| X2212 ×2 | `balsente.cpp:1386` | 256×4 NOVRAM, system + cartridge |
| LS259 (U9H) | `balsente.cpp:1395` | 7 lamp outputs + NOVRAM recall |
| 17-bit polynomial counter | `balsente_m.cpp:122` | hardware random number at 0x9a00 |

**No custom ASICs and no protection device on any in-scope set.** The only game-specific logic is
the Spiker cartridge's pixel-expand register and Grudge Match's steering decode.

### Clocks

| Clock | Value | Source |
|---|---|---|
| master | 20.000 MHz | `balsente.h:23`, "xtal verified" |
| pixel | 5.000 MHz | master / 4, `balsente.h:25` |
| 6809 E | 1.250 MHz | master / 16, `balsente.cpp:1378` — **divider not verified**, driver says so |
| sound board XTAL | 8.000 MHz | `sente6vb.cpp:107` — independent crystal |
| sound Z80 | 4.000 MHz | 8 / 2 |
| 8253 clk1, clk2 | 2.000 MHz | 8 / 4, `sente6vb.cpp:125` |
| ACIA tx/rx clock | 500 kHz | 8 / 16, `sente6vb.cpp:115`, supplied to *both* boards |
| random counter | 100 kHz | implied by `balsente_m.cpp:147` (CPU cycles × 12.5) |

**A single 40 MHz `clk_sys` divides exactly into every one of these**: 5 MHz = /8, 1.25 MHz = /32,
8 MHz = /5, 4 MHz = /10, 2 MHz = /20, 500 kHz = /80, 100 kHz = /400. No Bresenham enable is
needed anywhere. This is unusual and worth exploiting: every clock enable is a plain counter tap.

### Interrupts

| Line | Source | Behaviour |
|---|---|---|
| 6809 IRQ | vertical counter tap ("32L") | asserted at scanlines 0, 64, 128, 192, then 64 again; **cleared at the start of the next HBLANK** (`balsente_m.cpp:28`) |
| 6809 FIRQ | main-board ACIA | `balsente.cpp:1384`, `set_inputline`, level |
| 6809 NMI | not connected | — |
| Z80 IRQ | 8253 counter 2 OUT | `sente6vb.cpp:124`, level |
| Z80 NMI | 6VB ACIA, gated by counter-control bit 5 | edge, re-evaluated on each 500 kHz UART clock |

Vectors are at 0xfff0-0xffff in the EF bank — read them from the first target's ROM in Phase 0
rather than assuming.

### Memory map

Full map in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md). The shape that matters for RTL:

- 0x0000-0x07ff internal RAM, of which 0x0000-0x00ff is sprite RAM (two disjoint ranges)
- 0x0800-0x7fff video bitmap, 30,720 bytes, written by the CPU at full bus rate
- 0x8000-0x8fff palette RAM, 1024 × 4 bytes
- 0x9000-0x9fff I/O, decoded on 32-byte mirrors
- 0xa000-0xffff three banked ROM windows

### Video

- 5 MHz dot clock, HTOTAL 320, VTOTAL 264, visible 256×240, `ROT0`, ~59.19 Hz
  (`balsente.h:26-31`, `balsente.cpp:1408`).
- **No tilemap, no character generator.** The CPU draws pixels into the bitmap.
- 40 sprites, 8×16, 4 bytes per entry, read from `(0xe0 + i*4) & 0xff` — wrapping through two
  disjoint sprite-RAM ranges (`balsente_v.cpp:104`, and the loop at the end of the file).
- **Sprite pixel = high nibble of the palette index, background pixel = low nibble**
  (`balsente_v.cpp` `draw_one_sprite`). Nibble 0 is transparent. A sprite recolours what is
  under it; the palette bank is doing the work of a priority/blend table.
- Palette 1024 entries, 4 bits each of R, G, B, one byte per component
  (`balsente.cpp:1412`); a 2-bit bank selects 256 of them, **changed mid-frame** with a partial
  update (`balsente_v.cpp:63`).
- MAME does not model any scanout-time behaviour: it renders the bitmap per scanline and then
  overlays all 40 sprites. Whether the hardware overlays per scanline (almost certainly) is the
  first thing the write sweep must establish.
- No flip screen and no cocktail video flip in the driver — `minigolfct` is a cocktail set but
  the flip, if any, is not in the video code. To be confirmed in Phase 1.

### Sound

The 6VB board, in full, in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md). The RTL problem in one
sentence: **a 12-bit DAC value plus a 3-bit register address plus a 6-bit chip-enable mask sets
one of eight control voltages on one of six analog voices, and the voices must then behave like
analog voices**, including well enough that the board's own calibration routine converges.

MAME's model (`devices/sound/cem3394.cpp`) gives the transfer functions from the datasheet:
VCO −0.75 V/octave around `f = exp(V) · 431.894`; filter −0.375 V/octave, 1300 Hz at 0 V;
final gain and mixer balance −20 dB/V; waveform select and pulse width as voltage ranges.
Those are the specification. They are **not** a guarantee of matching a PCB, and MAME's known-bugs
list says as much.

### Protection

None on any in-scope set. The driver notes some cartridge types are still unknown and *may*
contain an undumped PAL — a risk against completing all 39 sets, not against the first ones.

### Per-game configuration

Everything that differs becomes `.mra` mod-byte configuration:

| Field | Values | Source |
|---|---|---|
| cartridge CD-bank mask | 0x00, 0x0c, 0x3f | `expand_roms` argument, `balsente.cpp:2914` |
| swap halves | 0/1 | `SWAP_HALVES` bit |
| bank count | 8 or 16 | maincpu region size |
| second bank register | present/absent | `st1002` configs |
| pixel-expand helper | present/absent | `spiker` |
| input multiplexer | present/absent | `teamht` |
| steering decode | present/absent | `grudge` |
| NOVRAM style | two 4-bit / one 8-bit | `rescraid` |
| ADC shift | 0, 1, 2, 32, or "no analog" | `config_shooter_adc`, `balsente.cpp:2968-2992` |
| light gun | present/absent | `m_shooter`, `nstocker` only |

## Component reuse map

Every row's "source" is a file that was located and whose header was read.

| block | plan | source |
|---|---|---|
| MC6809E | Port `mc6809i.v` (parameterised, cycle-accurate, `E`/`Q` clocked variant) | cavnex/mc6809 `mc6809i.v`, Greg Miller 2016. Dual-licensed; **take the stock BSD-3 option**, which permits source redistribution with the notice. Proven in jotego/jtcores (`modules/jtframe/hdl/cpu/mc6809i.v`), MiSTer-devel Arcade-Druaga, CoCo2_MiSTer, MO_MiSTer. Copy from jtcores, the maintained fork. |
| Z80 (sound) | Port T80 | Copy from the sibling that last proved it — Fuuki or MS32 `rtl/cpu/T80/`. BSD-style, Daniel Wallner. |
| 68000 (`shrike`, Phase 4) | Port fx68k or TG68K kernel | Seta `rtl/` copy (`dq_in` and integration fixes). GPLv3 / LGPL-3. |
| 8253 PIT | From scratch, 3 counters, the modes the 6VB uses | MAME `devices/machine/pit8253.cpp` as the spec. Checked for existing RTL: MiSTer ao486 carries one, but it is entangled with that core's bus; a standalone 3-counter PIT is ~200 lines. |
| 6850 ACIA ×2 | From scratch | MAME `devices/machine/6850acia.cpp` as the spec. Both ends are ours, so the link can also be verified end-to-end as one unit. |
| X2212 NOVRAM | From scratch: 256×4 BRAM + store/recall + MiSTer save file | MAME `devices/machine/x2212.cpp` as the spec. Save path per `references/hiscore.md`'s NVRAM section. |
| MM5837 noise | From scratch: 17-bit LFSR | `devices/sound/mm5837.cpp`. Same shape as the board's own 17-bit random counter. |
| 17-bit random counter | From scratch: LFSR clocked at 100 kHz | `balsente_m.cpp:122`. **RTL is more faithful than MAME here** — MAME indexes a precomputed table by CPU cycles. |
| **CEM3394 ×6** | **From scratch, from MAME's numerical model** | `devices/sound/cem3394.cpp` (Aaron Giles, m1macrophage). Surveyed by the "which boards carry this chip" method: MAME instantiates it in exactly two places — `bally/sente6vb.cpp` and `sequential/sixtrak.cpp` (the Sequential Circuits Six-Trak). Neither machine has an FPGA core. **No RTL exists.** |
| Video | From scratch | `balsente_v.cpp` is 199 lines; a bitmap scanout plus a 40-sprite line overlay. No existing core's pipeline is a better starting point than the driver itself. |
| SDRAM controller | Sibling copy | Seta `rtl/` (carries the `dq_in` capture fix). GPL-3.0-or-later as adapted. |
| Framework, `sys/` | Untouched | MiSTer-devel/Template_MiSTer, GPL-2.0-or-later. |
| CRT offset | `crt_adjust.sv` | rmonic79, GPL-3.0-or-later. |
| High scores | `hiscore.v` | JimmyStones/Hiscores_MiSTer, GPLv3. |
| Pause | `pause_control.sv` | Fuuki, this project's. |
| Debug probe / tracer | Seta `rtl/debug/` | this project's, headers intact. |
| Screen rotation | **Not needed** | every set is `ROT0`. |

## On-chip RAM budget

M10K on the 5CSEBA6: 5,570 Kbit. Baseline framework use is measured in Phase 0 before anything
is added; the figures below are the core's own declared memories.

| Memory | Bits | Notes |
|---|---|---|
| video bitmap 30,720 × 8 | 245,760 | true dual-port: CPU port + scanout port. **The one to watch** — it is read every pixel at 5 MHz and written by the CPU at 1.25 MHz, so it must be genuine dual-port, not arbitrated. |
| palette RAM 1024 × 32 | 32,768 | CPU write port + per-pixel read port |
| main RAM 2048 × 8 | 16,384 | includes sprite RAM |
| sound RAM 16,384 × 8 | 131,072 | 0x2000-0x5fff on the 6VB |
| sprite line buffer 256 × 8 | 2,048 | double-buffered → 4,096 |
| NOVRAM 2 × 256 × 4 | 2,048 | |
| CEM3394 state, 6 voices | small | register file, not a RAM |

Total core-owned ≈ 432 Kbit, about 8% of the device. ROMs live in SDRAM, so they cost nothing
here. **This core is not BRAM-constrained**, which means CRT v-size adjustment is affordable
(`references/crt_offset.md`).

## Memory plan

Everything in SDRAM; the DDR3 window is not used.

| Region | Size | Client |
|---|---|---|
| maincpu | 256 KB | 6809 bank windows AB/CD/EF through the cartridge address mapper |
| gfx1 | 128 KB | sprite line engine |
| audiocpu | 8 KB | 6VB Z80 — the same ROM for every game |
| 68k | 16 KB | `shrike` only |

Worst case 408 KB in a 128 MB module. The RTL's `localparam`s are the source of truth and the
`.mra` generator reads them (`references/sdram_ddr_maps.md`).

Per-scanline fetch budget: 40 sprites × 4 header bytes + 40 × 8 pixels × 4 bytes/row = 1,440
bytes worst case per line, against 320 pixel clocks at 5 MHz = 64 µs. At any plausible SDRAM
clock this is not close to a limit. The 8 KB sound ROM and the 6809's banked windows can be
cached or simply read on demand; a 1.25 MHz CPU leaves enormous slack.

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no
PCB here. MAME is the accuracy target and its acknowledged guesses are inherited deliberately.
Each goes in `docs/MAME_KLUDGES.md` when it is implemented, with what MAME does, what the
hardware is suspected to do, and what would settle it.

**Where a vendored module and MAME disagree, record it and keep the module.** A silicon-derived
disagreement is evidence about the chip; MAME's is evidence about MAME. It goes in
`docs/MAME_KLUDGES.md`, not into a "fix", until one side is shown to describe the chip.

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands, with
what would make it correct.

**Transcribe the reference literally first, then look for the chip.** Build MAME's version, get
pixel-exact (or trace-exact) agreement with captured references, and only then experiment — with
the experiment on an OSD switch so it is an A/B, not a rebuild.

**One `.rbf` for all games.** Per-set differences are `.mra` mod-byte configuration.

**Two Quartus revisions, `BallySente_stp` and `BallySente`,** differing only by a `DEBUG_ISSP`
macro. See [`WORKFLOW.md`](WORKFLOW.md).

**Licence: GPL-3.0.** Strictest dependency wins; `hiscore.v` and `crt_adjust.sv` are GPL-3.
`mc6809i.v` is taken under its BSD-3 option, which is compatible. Every dependency and its
obligations go in `THIRD-PARTY.md`. `sys/` is never edited.

**No multiplies, no divides, in the 2D pipeline.** The sprite overlay is shifts and adds. The
CEM3394 voices are the exception and are budgeted as DSP blocks: exponential V→frequency lookup
plus a filter, six voices time-multiplexed on one pipeline.

**One 40 MHz `clk_sys`, every clock enable a counter tap.** Justified above: all nine board
clocks divide exactly. This removes a whole class of fractional-enable bugs the previous cores
hit.

**The CEM3394 voice is built and verified as a standalone instrument before the board is wired
to it.** A bench that sweeps each control voltage across its datasheet range and checks pitch,
duty cycle, filter corner and gain against MAME's model, plus the calibration loop run against
the real oscillator output. Sound is Phase 3, but **the voice spike happens in Phase 0** because
it is the one thing that could invalidate the project.

**The sprite overlay is line-based, not frame-buffered.** 40 sprites × 8 pixels is 320 pixel
writes per line against 320 clocks; a double-buffered 256-byte line buffer is sufficient and
matches what the hardware must be doing.

## Pitfalls that already bind decisions here

| Entry | What it binds here |
|---|---|
| "A web search returning nothing is not evidence that nothing exists" [MS32] | The CEM3394 "no RTL exists" claim above is made by the method that entry prescribes — enumerate the boards carrying the chip (`grep -rl cem3394 $MAME_SRC` → two drivers), then look for *those boards'* cores — not by a name search. The same check is owed to the 8253 and 6850 before writing either. |
| "Read both halves of a mechanism before changing it: the draw loop AND the pixel op" | The sprite loop runs `0xe0` upward through a wrapping 8-bit index while the pixel op writes unconditionally. Draw order and overlap winner must both be read before any depth decision. |
| "Suspect your own integration before any vendored module" | `mc6809i.v` ships in four or more working cores; a 6809 bus problem is this project's glue until proven otherwise. |
| "Sprite lists, line buffers and snapshots" | Nothing on this board is double-buffered by the hardware as far as the driver shows. The write sweep decides; do not add a vblank latch to make the picture stable. |
| "ROM loading: .mra, byte order, deployment" | The cartridge bank tables are an address *mapping*, not a ROM rebuild — the `.mra` must not try to reproduce `expand_roms` by reordering bytes. |
| "Driving MAME as a reference generator (Lua)" | The 6VB Z80 is a second CPU inside a MAME *device*; its trace path is `:audio6vb:audiocpu`, not a top-level tag. |

## Phased roadmap

**Phase 0 — Vendoring spike, the measurements, and the CEM3394 answer. The gate.**

Vendor `mc6809i.v` and T80 into `rtl/` with a `PROVENANCE.md` each. Run every upstream testbench
unchanged before editing anything. Stand the 6809 up in its own Quartus project
(`rtl/synth_check/`) with the bus wrapper and the memory transport and nothing else.
Exit criteria:

1. **Every vendored module's own tests pass unchanged, on arrival.**
2. **The 6809 boots `sentetst` and matches MAME's bus trace**, diffed access by access, every
   peripheral stubbed to what MAME returns.
3. **Measured CPI on real game code** against 1.25 MHz, split between execution and memory stall.
4. **Standalone Fmax and area for the 6809 at this project's settings**, with the constraint that
   proves it committed in the same commit as the measurement.
5. **A single CEM3394 voice, in RTL, reproduces MAME's model across a control-voltage sweep**,
   and the 6VB calibration routine converges against the RTL oscillator driving 8253 counter 0
   in simulation. **If this criterion fails, the project stops here and the scope goes back to
   the user** — a Bally/Sente core with wrong sound is not worth building.

**Phase 1 — Video, against a software model.**

Build the MAME capture pipeline first (`mame_capture.py` + a `render_model.py` reproducing
`balsente_v.cpp`), get it pixel-exact on captured frames, then check RTL against the model.
The video write sweep is **done** and it decides the architecture: the core races the beam.
`scripts/write_timing.py` over 900 frames of four runs shows every set writing sprite RAM and
video RAM during active display, with no concentration in vblank -- `hattrick` writes the sprite
list 1,698 times a frame across all 264 lines. There is no safe point to latch or snapshot at, so
nothing is buffered a frame ahead: the background is read as the line is drawn, the sprite engine
fills the next line into a line buffer, and the palette bank is sampled per line
(`docs/HARDWARE_NOTES.md`, "Raster timing: the board races the beam").

**MAME cannot be the pixel reference for timing**, only for the rendering function. It renders the
whole frame at vblank start from the RAM as it stands then, and calls `update_partial()` only for
the palette bank -- never for a sprite-RAM or video-RAM write. On moving content MAME shows the
end-of-frame state uniformly down the screen where the board shows line 100 as RAM stood at line
100. Exit criteria, amended accordingly:

1. `scripts/render_model.py` renders MAME's own captured frames pixel-identically, over a set of
   scenes that between them exercise sprites, both flips, wrapping, edge clipping and a mid-frame
   palette-bank change. **Met**: 9 captures across 6 games, 0 pixels differing.
2. The RTL matches a scanline-accurate model, built from a write log with raster positions, on the
   same scenes -- silent, in simulation.
3. Where the RTL and MAME differ, every difference is attributable to a write during active
   display, and that is written into `docs/MAME_KLUDGES.md` rather than tuned away.

**State: 1 met, 2 met, 3 open.** `rtl/video/` is written and `sim/video_tb` reproduces the beam
model on 8 of 9 captured frames to the pixel, including frames with 2,018 mid-frame writes. The
ninth differs on 6 pixels of 61,440 where a sprite update straddles the line the engine is
reading it on, and the RTL is the more faithful of the two there (`docs/HACKS.md`). Standalone
synthesis, Quartus 17.0.2, 5CSEBA6U23I7: **177 ALMs (<1%), 254 registers, 1 M10K (2,048 bits --
the line buffer exactly), 0 DSP, worst setup slack +18.414 ns at 40 MHz, Fmax 151.84 MHz**
(`rtl/video/synth_check/`). Criterion 3 needs the RTL-versus-MAME differences classified across
a run, which needs the CPU driving the RAM rather than a replayed write log -- Phase 2.

**Phase 2 — Hardware bring-up and the first games.**

SDRAM backend with all clients, ROM download, the cartridge address mapper, `.mra` generation,
inputs, DIPs, NOVRAM with a real save file, the ISSP probe and the OSD debug page. The standard
feature set: CRT offset and v-size, hiscore, fast DDR ROM loading, HDMI scaling and crop, audio
mix, HDMI-only options hidden under direct video, CRT offset parameters hidden until enabled,
peripheral menus only for the games that use them. **No screen rotation and no flip screen** —
every set is `ROT0` and the driver has no flip; if the cocktail set proves otherwise it is added
here. A fake **Pause** input on a `J1` slot, shared with the OSD pause and hiscore's pause.
Exit criteria: `sentetst` passes its own diagnostic, and `cshift`, `hattrick`, `toggle` and
`gghost` boot and play on a DE10-nano, silent.

**Phase 3 — Sound.**

The 6VB board end to end: Z80, 8253, both ACIAs and the serial link, the DAC/register/chip-select
path, the MM5837 noise source, and the six voices from the Phase 0 spike promoted to a full
instrument with the RC and mixer network. Exit criteria: the calibration routine converges on
hardware; register-write traces captured from MAME reproduce correct audio by ear and by a
decoded capture against MAME's output, with every known divergence written into
`docs/HACKS.md` and `docs/MAME_KLUDGES.md` rather than tuned away.

**Phase 4 — The rest of the list, and accuracy.**

The remaining sets and every clone's `.mra`; the analog peripherals (trackball, steering wheel,
Night Stocker's light gun with mouse support and a synthetic crosshair, Stompin's 32 pads,
Team Hat Trick's multiplexer, Grudge Match's three wheels); the Spiker expand helper; `rescraid`'s
NOVRAM variant; and **`shrike`** — the second 68000 and its shared memory, knowing MAME itself
does not run it properly. `docs/MAME_KLUDGES.md` and `docs/HACKS.md` are the deliverables that
say what is still not right and what would settle it.

**Phase 5 — CEM3394 accuracy against real hardware.** A decision with evidence rather than a
default: if PCB or Six-Trak recordings can be obtained, compare and refine the voice model, and
feed corrections back into a written description of where MAME's model is wrong. Only worth doing
if Phase 3 leaves audible doubt.

**Phase 6 — Savestates and cheats.** Optional but desirable. Not before Phase 4.

## Verification strategy

- **MAME is a reference generator, driven from scripts, not a thing to eyeball.** Boot traces,
  bitmap and palette dumps at known frames, sprite-RAM snapshots, sound register-write logs.
- **The software model comes before the RTL.** The model is checked against MAME first; the RTL
  against the model.
- **Every vendored module is verified against MAME before it is wired to anything**, and its own
  testbench is the regression for every later change to it.
- **The sprite format gets the "every bit of an image exactly once" check** before any ROM is
  involved: 64 bytes, 16 rows, 4 bytes per row, 8 pixels.
- **`.mra` files are generated, not written**, re-read byte-for-byte against an image built from
  `ROM_START`, and gated on an XML well-formedness check before deploy. Each must also pull in
  the 6VB device ROM, which belongs to no game set.
- **Sound is verified structurally, not by diff.** MAME's CEM3394 is not ground truth; saying so
  in advance is what keeps Phase 3 from turning into tuning against a known-wrong reference.

## Repository setup

Seeded from **MiSTer-devel/Template_MiSTer**, `Template.*` renamed to `BallySente.*` and split
into the `BallySente_stp` and `BallySente` revisions; the Quartus 13 project dropped. Quartus
**17.0.2**. Conventions are in [`WORKFLOW.md`](WORKFLOW.md) and `CONVENTIONS.md`.

## Open items

**The CEM3394 is the project.** Known: the datasheet transfer functions, the component values on
the 6VB (R_vco 301 kΩ, C_vco 2 nF, C_vcf 33 nF, C_ac 10 µF), and MAME's numerical model. Assumed:
that a digital voice built to those functions is close enough that the board's calibration
converges and the music is recognisably right. Closed by Phase 0 exit criterion 5.

**The 6809 clock divider is unverified.** MAME says "xtal verified but not speed". Known: 20 MHz
crystal. Closed by comparing measured frame timing and IRQ cadence against a PCB recording, or
left as MAME's assumption and logged in `MAME_KLUDGES.md`.

**Whether the sprite overlay is per-scanline.** MAME overlays whole sprites after drawing all
scanlines. Almost certainly the hardware overlays during scanout. Closed by the Phase 1 write
sweep plus a scene where the CPU writes sprite RAM mid-frame.

**Unknown cartridge types.** The driver says some are unknown and may contain an undumped PAL.
Affects completeness in Phase 4 only. Closed by getting each set to boot, or by recording which
do not and why.

**Cocktail flip.** `minigolfct` is a cocktail set and the driver has no flip logic. Closed by
running it in MAME and looking.

## Next steps

1. ~~Approval of this roadmap.~~ Given.
2. ~~Phase 0: vendor `mc6809i.v` and T80 with `PROVENANCE.md`.~~ Done; `mc6809i` has no upstream
   testbench to run, which `rtl/cpu/mc6809/PROVENANCE.md` records.
3. ~~Phase 0: build the MAME trace harness for `sentetst`.~~ Done for `:maincpu`; criteria 2 and 3
   met. The `:audio6vb:audiocpu` side is still to do.
4. ~~Phase 0: port the CEM3394 chain to a software model.~~ Done; the fixed-point
   stability question is answered ([`CEM3394_SPIKE.md`](CEM3394_SPIKE.md)).
5. ~~Phase 0: check the model against MAME's own audio.~~ Done for `cshift`: level +0.00 dB,
   worst octave 0.01 dB, against a 1.28 dB control. Repeat for `snakepit`, `gimeabrk` and
   `nametune` to cover high resonance, noise mixing and filter FM.
6. Phase 0: the CEM3394 voice in RTL, checked against the model; then the calibration-loop
   bench, which needs the sound Z80 and the 8253 — **the rest of the gate**.
7. ~~Phase 0: standalone Fmax and area for `mc6809i`.~~ Done: 1,472 ALMs, Fmax 79.3 MHz with
   the enable multicycle and 51.78 MHz without, against a 40 MHz `clk_sys`.
8. Fill `THIRD-PARTY.md` from the reuse map, with each dependency's licence text located.
