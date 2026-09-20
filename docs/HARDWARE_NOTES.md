# Bally/Sente SAC-I — hardware notes

Reference: MAME `src/mame/bally/balsente.{cpp,h}`, `balsente_m.cpp`, `balsente_v.cpp`,
`bally/sente6vb.{cpp,h}`, `devices/sound/cem3394.cpp`. Tree at commit `5ae594ba` (`E:/mame`).
Driver by Aaron Giles. Everything below is read out of those files; where the driver says a
value is unverified, this file says so too.

A cartridge platform: one motherboard (SAC-I), one audio board (6VB), and a game cartridge
carrying program ROMs, sprite ROMs and its own NOVRAM. 41 sets in the driver, 39 of them on
this hardware.

## Feasibility: the CEM3394

**This is the one part of the board with no FPGA precedent anywhere, and it decides the
project.** The 6VB audio board carries six Curtis CEM3394 chips — complete *analog*
synthesizer voices (VCO with triangle/saw/pulse and PWM, a mixer with external input, a
resonant VCF, a VCA), each controlled by eight analog control voltages written from a 12-bit
DAC. There is no digital register interface to reimplement: the sound program sets voltages.

### What MAME's model actually is

**MAME rewrote this device onto its virtual-analog primitives, and the driver's "not perfect"
note predates that work.** `devices/sound/cem3394.cpp` no longer computes waveforms itself: it
wires up `va_vco`, `va_lpf4`, `va_vca` and `filter_rc` and maps the eight control voltages onto
their parameters. The rewrite landed in a series of commits — `c21edf7fc9a` (self-oscillation),
`f0fa6f910de` (va_vcf), `a021da1579e` (pulse width), `7d6c16dbdac` (va_vco), `e47154a36e5`,
`4515e9a34eb` — with `va_vcf.cpp` last changed 2026-07-04 and `va_vco.cpp` 2026-06-28. The
"CEM3394 emulation is not perfect" line in `balsente.cpp` was last touched **2026-05-24**
(`git log -S`), before any of it.

The signal chain, as built in `device_add_mconfig()`:

```
  va_vco ramp  --+
  va_vco pulse --+
  va_vco tri   --+---> va_lpf4 ---> filter_rc ---> va_vca ---> out
  mm5837 noise --+     (4-pole)     (highpass)   (final gain)
   (mixer gains)         ^
                         |
  va_vco tri --> va_vca(filt_fm) --+   filter FM, gain = mod_amount * 0.5
```

- **`va_lpf4`** is a Zavalishin TPT ("zero-delay feedback") Moog ladder: four one-pole stages,
  a resonance feedback path with `tanh` saturation, low-frequency gain compensation, coefficients
  `g = tan(w·T/2)` recomputed only when the cutoff changes. Roughly a dozen multiplies per sample.
- **`va_vco`** is a polyBLEP/polyBLAMP anti-aliased oscillator producing ramp, pulse and triangle
  from one phase accumulator, with hard sync available but **not used here** (`SYNC_TYPE_NONE`),
  which removes most of its complexity.
- **`filter_rc`** high-pass, R = 11 kΩ internal, C = `c_ac` = 10 µF.
- The VCF runs at `max(96 kHz, sample_rate)` to keep the saturator's distortion products out of
  the audible band.

That is a precise, portable specification — not the situation the roadmap was written against.

Consequences, revised:

1. **There is still nothing to port.** No FPGA implementation of this chip, or of the only other
   machine MAME gives it to (`sequential/sixtrak.cpp`, the Sequential Circuits Six-Trak), exists.
   The work is writing it.
2. **But the specification is now a good one.** A structured virtual-analog chain of four named
   primitives is a far better thing to port than a bag of numerical approximations, and each
   primitive can be ported and checked on its own before they are chained.
3. **MAME is a usable reference again, with a caveat.** The driver's blanket "not perfect" is
   stale, but MAME's chain is still a model of an analog part, not the part. Agreement with MAME
   remains the bar for Phase 3; agreement with a PCB is Phase 5 and needs recordings nobody has
   captured yet.
4. **The board calibrates itself**, and that is the real test. The sound Z80 routes a voice's
   oscillator into 8253 counter 0 and measures it. MAME fakes this by feeding the counter the
   frequency its own model computed (`update_counter_0_timer()`). In RTL the digital oscillator
   drives the counter for real, so the calibration loop works as it does on the PCB — **the RTL
   is more faithful than MAME here**, and if the voice's pitch mapping is wrong the loop fails
   loudly instead of sounding slightly off.

Cost estimate, from the structure above: roughly 20 multiplies per voice per sample. Six voices
at 96 kHz is 576 k samples/s, so about 12 M multiplies/s against a 40 MHz clock — comfortably one
time-multiplexed DSP pipeline. The expensive operations (`tan`, `tanh`, the CV exponentials, the
`1/(1+res·G4)` divide) are either lookup tables or run only when a control voltage changes, which
is at CPU-write rate. **The arithmetic is not the problem.** What remains genuinely open is
whether a fixed-point port of this chain stays stable at high resonance and converges the board's
calibration loop — which is what the Phase 0 spike measures.

Everything else on the board is conventional 1984 TTL and well within scope.

## Sets

39 sets on SAC-I hardware. Two (`triviaes4`, `triviaes5`) run different Maibesa hardware that
MAME does not emulate (`MACHINE_NOT_WORKING`) — out of scope.

Machine variants, all sharing `balsente()`:

| Config | Sets | Difference from the base |
|---|---|---|
| `balsente` | most | — |
| `teamht` | teamht | 4-way input multiplexer at 0x9000-0x9007, extra read at 0x9404 |
| `grudge` | grudge, grudgei, grudgep | three steering wheels decoded at 0x9400 |
| `st1002` | nstocker(a), sfootbal, stompin, nametune(a) | second bank register at 0x9f00 |
| `spiker` | spiker, spikera, spikerb | `st1002` plus the pixel-expand helper at 0x9f80-0x9f8f |
| `shrike` | shrike | adds a 68000 @ 8 MHz and shared memory at 0x9e00-0x9fff |
| `rescraid` | rescraid, rescraida | non-cartridge; NOVRAM is one 8-bit device, not two 4-bit |

### ROM footprint

| Region | Size | Notes |
|---|---|---|
| `maincpu` | 0x20000 (128 KB) | 0x40000 (256 KB) for `nametune`, `nametunea` |
| `gfx1` | 0x10000 (64 KB) | 0x20000 for `shrike` (two banks); 0x8000 for one set |
| `audiocpu` | 0x2000 (8 KB) | **on the 6VB board, identical for every game** (`8002-10 9-25-84.5`) |
| `68k` | 0x4000 (16 KB) | `shrike` only |

Worst case 256 + 128 + 8 + 16 = 408 KB. Fits the SDRAM module many times over; the DDR3
window is not needed. The 6VB audio ROM is a MAME *device* ROM, not part of any game set — each
`.mra` has to pull it in explicitly.

## CPUs and clocks

Master clock 20 MHz (XTAL verified in the driver; the CPU divider is marked "xtal verified but
not speed").

| CPU | Part | Clock | Role |
|---|---|---|---|
| main | MC6809E | 20/16 = 1.25 MHz | everything: game logic, drawing into the bitmap, I/O |
| sound | Z80 | 8/2 = 4 MHz | on the 6VB board; drives the six CEM3394s |
| `shrike` only | 68000 | 8 MHz | motion-base controller for the Shrike Avenger prototype |

The two boards talk over a **serial link**: a 6850 ACIA at each end. The 6VB supplies the
clock — 8 MHz / 16 = 500 kHz — to its own ACIA and, through `clock_out_cb`, to the main
board's. Main-board ACIA IRQ drives the 6809's **FIRQ**; on the 6VB
the ACIA drives the Z80's **NMI**, gated by bit 5 of the counter-control register.

## Main CPU memory map

| Range | Access |
|---|---|
| 0x0000-0x007f | sprite RAM, 32 entries × 4 bytes |
| 0x0080-0x00df | work RAM |
| 0x00e0-0x00ff | sprite RAM, 8 more entries |
| 0x0100-0x07ff | work RAM |
| 0x0800-0x7fff | **video RAM**, 256×240 at 4bpp packed two pixels per byte (30,720 bytes exactly) |
| 0x8000-0x8fff | palette RAM, 1024 entries × 4 bytes, 4 bits each of R, G, B |
| 0x9000-0x9007 | w: ADC start, input 0-7 |
| 0x9400 | r: ADC data |
| 0x9800-0x981f (mirror 0x0060) | w: LS259 U9H output latch, D7, address from bits 4:2 |
| 0x9880-0x989f | w: random generator reset |
| 0x98a0-0x98bf | w: bank select for 0xa000-0xdfff (bits 6:4) |
| 0x98c0-0x98df | w: palette bank select (2 bits) |
| 0x98e0-0x98ff | w: watchdog reset |
| 0x9900 / 0x9901 | r: DIP bank SWH / SWG (active low) |
| 0x9902 | r: self-test, left coin, 6 external inputs (active low) |
| 0x9903 | r: **VBLANK (active high, bit 7)**, right coin, 4 external inputs, start 1/2 |
| 0x9a00-0x9a03 | r: hardware random number |
| 0x9a04-0x9a05 | r/w: 6850 ACIA to the sound board |
| 0x9b00-0x9bff | r/w: system NOVRAM (X2212) |
| 0x9c00-0x9cff | r/w: cartridge NOVRAM (X2212) |
| 0x9f00 | w: second bank register (`st1002` cartridges) |
| 0xa000-0xbfff | banked ROM "AB" |
| 0xc000-0xdfff | banked ROM "CD" |
| 0xe000-0xffff | ROM "EF" (banked only on `st1002`) |

LS259 outputs 0-6 drive lamps; output 7 is **NOVRAM recall** (active low through
`nvrecall_w`).

### Interrupts

- **IRQ** every 64 scanlines — asserted at scanline 0, 64, 128, 192, then back to 64 —
  cleared at the start of the next HBLANK. Generated by "32L" on the schematic, i.e. a
  vertical counter tap.
- **FIRQ** from the main-board ACIA.
- **NMI** not connected.

### Cartridge banking

`expand_roms(cd_rom_mask)` is not a ROM transform — it is a table of bank pointers describing
how a given cartridge type is wired. Per 8-bank group:

- AB bank *n* → `maincpu[0x0000 + 0x2000*n]`
- CD bank *n* → `maincpu[0x10000 + 0x2000*n]` if bit *n* of `cd_rom_mask` is set, otherwise the
  **common CD ROM** at `maincpu[0x1c000]`
- banks 6 and 7 always use the common CD ROM
- EF → `maincpu[0x1e000]`
- `SWAP_HALVES` (bit 6 of the argument) XORs every one of those offsets with 0x2000

Cartridge types actually used: `EXPAND_ALL` (0x00), `EXPAND_NONE` (0x3f), `0x0c`, each
optionally with `SWAP_HALVES`. Sets with a 256 KB `maincpu` have 16 banks, selected by an extra
bit from the 0x9f00 register.

In RTL this is a small combinational address mapper driven by a per-game configuration byte
carried in the `.mra` — the same shape as the Taito F2 core's `game_board_config.sv`. The
driver notes some cartridge types are still unknown and may contain an undumped PAL.

## Video

`screen.set_raw()`:

| | Value |
|---|---|
| pixel clock | 20/4 = 5 MHz |
| HTOTAL | 320 (0x140) |
| HBEND / HBSTART | 0 / 256 |
| VTOTAL | 264 (0x108) |
| VBEND / VBSTART | 16 / 256 |

H = 15.625 kHz, V = 59.19 Hz. Visible 256×240, `ROT0` — horizontal screen, unusually for the
era. `VIDEO_UPDATE_BEFORE_VBLANK` is set.

### Background

There is no tilemap and no character generator. The 6809 draws directly into a 256×240 4bpp
packed bitmap at 0x0800-0x7fff, two pixels per byte, high nibble left. Scanout reads it
linearly.

### Sprites

40 entries, read from sprite RAM starting at 0xe0 and wrapping: `(0xe0 + i*4) & 0xff` for
i = 0..39, i.e. the eight entries at 0xe0-0xff first, then the 32 at 0x00-0x9f.

| Byte | Field |
|---|---|
| +0 | bit 7 = flip Y, bit 6 = flip X, bits 2:0 = image number high bits |
| +1 | image number low 8 bits |
| +2 | Y position, **offset by 17 pixels**, wrapping at 256 |
| +3 | X position |

Each sprite is 8 pixels wide by 16 rows, 4 bytes per row, 64 bytes per image, 11-bit image
number masked by the gfx region size.

**The sprite pixel is not a colour — it is the high nibble of a palette index.** For each
sprite pixel the drawn pen is `(sprite_nibble << 4) | background_nibble` within the current
256-entry palette bank. Sprite nibble 0 is transparent (background shows through unchanged).
That means a sprite recolours the bitmap under it rather than replacing it, and the palette
bank is doing the work of a priority/blend table.

Pixels are clipped to x in 0..255 and skipped for y < 16 + VBEND.

### Palette

1024 entries × 4 bytes: byte 0 red, byte 1 green, byte 2 blue, 4 bits each → 12-bit colour.
`palette_select_w` picks one of four 256-entry banks. It calls
`m_screen->update_partial(vpos - 1 + VBEND)` — **the palette bank is switched mid-frame**, so
the bank must be sampled per scanline, not per frame. Same for Shrike Avenger's sprite-bank
select.

MAME's boundary is 16 lines below the write, because `vpos()` is already absolute and the
driver adds `VBEND` to it a second time. Measured, not inferred: `cshift` frame 2285 writes
the bank at raster line 61 and MAME changes it at visible row 61 (absolute 77), and forcing
the model to any other row costs 195 pixels or more. `docs/MAME_KLUDGES.md` has the entry;
the core follows MAME.

### Raster timing: the board races the beam

Sprite RAM, video RAM and the palette are all plain CPU RAM written by a 1.25 MHz CPU while the
beam is live. **Measured, not assumed** (`scripts/write_timing.py`, 900 frames each, writes
counted by scanline from vblank start):

| set | state | sprite RAM writes/frame | in vblank | video RAM writes/frame | in vblank |
|---|---|---|---|---|---|
| `cshift` | play | 84.0 | 0.0% | 42.2 | 0.0% |
| `cshift` | attract | 0.4 | 0.0% | 110.5 | 0.2% |
| `rescraid` | play | 120.8 | 2.1% | 42.9 | 0.8% |
| `hattrick` | play | 1697.6 | 0.6% | 21.5 | 1.8% |

**There is no safe window.** Every set writes both regions during active display, and none
concentrates its writes in vblank -- `hattrick` writes the sprite list 1,698 times a frame,
spread evenly across all 264 lines. So nothing can be latched or snapshotted at vblank without
showing something the board never showed.

The core therefore **scans out line by line from the live RAM**, like the board: the background
is read as the line is drawn, the sprite engine builds the next line into a line buffer, and the
palette bank is sampled per line. Nothing is buffered a frame ahead.

**MAME does not do this**, and that is worth being clear about rather than discovering later.
`screen_update_balsente` renders the WHOLE frame at vblank start from the RAM as it stands then
(`VIDEO_UPDATE_BEFORE_VBLANK`), and `update_partial()` is called only from `palette_select_w` and
Shrike's sprite-bank select -- never for a sprite-RAM or video-RAM write. So MAME shows the
end-of-frame state uniformly down the screen, where the board shows line 100 as RAM stood at line
100. On moving content the two cannot agree, and the board is right.

The consequence for verification: `scripts/render_model.py` validated against MAME's frames
checks the RENDERING FUNCTION -- palette decode, sprite composition, flips, wrapping, clipping --
because it is fed the same snapshot MAME rendered from. It does not check timing.

**Timing is checked against `render_model.py`'s beam mode**, which starts from the RAM as it
stood at the first line of the frame and applies every write as the beam reaches it
(`mame_capture.py --beam`). Two things make it trustworthy: replaying its write log onto the
start RAM reproduces the end-of-frame RAM byte for byte, and on frames with no visible late
write it agrees with MAME exactly.

**How far apart are they?** Measured on rendered frames, not estimated:

| frame | beam vs MAME |
|---|---|
| `cshift` 3000, 1200, 3523 | identical |
| `hattrick` 3028 | identical |
| `rescraid` 3062 | **218 pixels, 0.35%, rows 64-107** |

So the divergence is real but small and occasional. `scripts/beam_scout.py` counts candidate
frames across a whole run -- 22.4% of `cshift` play frames, every frame of `hattrick` and
`rescraid` -- but that is an UPPER BOUND on bytes, not a count of wrong pixels. `cshift` frame
3523 has 1,089 late writes touching 2,202 pixels and renders identically, because every one of
those indices maps to the same RGB in the active bank. Find candidates with the scout, then
render them to see what actually differs.

### A sprite line buffer holds the NIBBLE, not the composed index

Each sprite reads its low nibble from the BACKGROUND, not from an earlier sprite's result
(`balsente_v.cpp`: `old` points into `m_expanded_videoram`). Overlapping sprite pixels are
common -- 27 to 110 per frame across the captures in `debug/`, up to two deep -- so a line buffer
storing the composed 8-bit palette index would give the second sprite the first one's low nibble.
Store the 4-bit sprite nibble and a written flag; concatenate with the framebuffer at scanout.

## Sound: the 6VB board

Z80 @ 4 MHz. Memory: ROM 0x0000-0x1fff, RAM 0x2000-0x5fff, ACIA write at 0x6000-0x6001, ACIA
read at 0xe000-0xe001.

I/O (masked to 8 bits):

| Port | Function |
|---|---|
| 0x00-0x03 | 8253 PIT |
| 0x08-0x0f | r: counter state — bit 1 counter 0 OUT, bit 0 inverse of the counter-0 flip-flop |
| 0x08-0x09 | w: counter control — bit 5 NMI enable, bit 4 FF clear (low), bit 3 FF D input, bit 2 FF preset (low), bit 1 counter 0 GATE, bit 0 audio enable |
| 0x0a | w: DAC data, upper 6 bits |
| 0x0b | w: DAC data, lower 6 bits |
| 0x0c-0x0d | w: CEM3394 register select (3 bits) |
| 0x0e-0x0f | w: CEM3394 chip enable, 6 bits, active high, one bit per chip |

PIT: counters 1 and 2 clocked at 8/4 = 2 MHz; counter 2 OUT is the Z80 IRQ; counter 0 OUT
gates counter 1 through an inverter; counter 0's clock comes from a flip-flop the CPU can
drive manually or from a voice's oscillator (the calibration path above).

Also on the board: an MM5837 noise generator through a high-pass RC (68k+1k, 2.2 µF) feeding
every CEM3394's external input. CEM3394 component values: R_vco 301 kΩ, C_vco 2 nF, C_vcf
33 nF, C_ac 10 µF. Output is mono, six voices summed at 0.5 each.

## NOVRAM, ADC, random

**NOVRAM.** Two X2212 (256×4) with auto-save: system at 0x9b00, cartridge at 0x9c00. Recall is
driven by LS259 output 7. `rescraid` instead uses one 8-bit device split across two halves.
This is per-game persistent storage that must survive a power cycle — it needs the MiSTer
save path, not just `Hiscore.v`.

**ADC.** Eight select addresses at 0x9000-0x9007, data at 0x9400, conversion modelled as 50 µs
(the driver notes Mini Golf depends on the delay). Analog inputs are read at VBLANK and
latched. Per-game `adc_shift` scales them; a shift of 32 is the flag for "return the raw
value" (Stompin', Shrike Avenger). For the normal games, even-numbered selects return the sign
(0x00/0xff) and odd-numbered the magnitude.

**Random number.** A 17-bit polynomial counter clocked at 100 kHz, read at 0x9a00. MAME
precomputes the whole sequence and indexes it by CPU cycles × 12.5 (1.25 MHz / 100 kHz); in
RTL it is simply an LFSR clocked at 100 kHz, which is what the hardware is. The reset write at
0x9880 does nothing in MAME.

## Per-game peripherals

| Game | Control |
|---|---|
| Stocker | steering wheel + pedals (has a MAME artwork layout) |
| Grudge Match | three steering wheels, decoded as direction+movement bits at 0x9400 |
| Night Stocker | light gun; the beam position is returned four bits at a time across the four IRQ scanlines of a frame (`nstocker_bits_r`) |
| Mini Golf, Goalie Ghost, Snake Pit, Snacks'n Jaxson, Gimme A Break, Spiker | trackball |
| Stompin' | 32 pads, raw ADC |
| Team Hat Trick | four multiplexed input banks |
| Shrike Avenger | analog yoke plus a motion base (never finished; the 68000 side is not fully understood) |

The light gun, trackball and steering games each need their OSD peripheral group gated by the
`.mra` mod byte (`references/osd_and_peripherals.md`).

`spiker_expand_r/w` at 0x9f80 is a tiny drawing helper on the Spiker cartridge: it holds a bit
pattern, a colour and a background colour, rotates each nibble of the pattern one bit per read
and returns two expanded pixels. Pure combinational logic plus three registers.

## Kludges and soft spots

- MAME: "CEM3394 emulation is not perfect" — see the feasibility section.
- MAME: "Shrike Avenger doesn't work properly"; the 68000 motion-base side returns a canned OK
  status (`shrike_shared_6809_r` case 6) because the motors are not hooked up.
- Some cartridge types are unknown and may contain an undumped PAL.
- The 6809 clock divider is an assumption, not a measurement.
- `random_reset_w` is a no-op in MAME; on hardware it presumably reloads the polynomial
  counter. Anything depending on that would diverge.
- Two Maibesa Trivial Pursuit sets run different hardware entirely and are not emulated.
