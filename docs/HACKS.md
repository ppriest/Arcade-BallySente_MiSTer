# Hacks, approximations and workarounds in this core

Everything in this core's own RTL, scripts or `.mra` layout that is known not to be what the
hardware does: a stand-in, a shortcut, a value chosen to make something work, a workaround for a
tool. Each entry is added in the commit that introduces the hack and removed in the commit that
removes it.

This is not `MAME_KLUDGES.md`. That file lists MAME's own guesses that the core reproduces on
purpose because MAME is the reference. This file lists what is ours.

Rules:

- An entry cites `file:line` (or a module and signal name if the line moves often), and the
  evidence column says what was measured, or "unverified".
- "What would make it correct" names the work, not "fix later".
- A hack whose entry is missing is a bug. A hack whose entry is stale is worse: update it in the
  same commit as the code.
- Severity is what a player or a verifier would see: **visible** (wrong pixels, wrong sound, wrong
  timing a game can hit), **latent** (wrong only for input no in-scope set produces), **tooling**
  (affects the build or the bench, not the bitstream).

| What | Where | Why it is a hack | What would make it correct | Evidence | Severity |
|---|---|---|---|---|---|
| The beam model applies sprite-RAM writes at line boundaries; the RTL reads each entry atomically | `scripts/render_model.py` `render_beam()` | The model advances sprite RAM to the start of the line being built, so a multi-byte sprite update split across that boundary is seen half-applied. The RTL reads each entry once, at its own moment in the line, which is what a board that fetches the list during the line does and cannot tear | Knowing the real board's sprite fetch schedule -- MAME models none of it | Measured on `stocker-edgebeam`: 6 pixels of 61,440 (0.01%), where entry 12's Y was written at line 81 pixel 256 and its X at line 82 pixel 40. The model saw the new Y with the old X; the RTL saw both old. Eight of the nine beam frames compared are exact | latent |
| Sync pulse positions are a guess | `rtl/video/video_timing.sv` | MAME's `set_raw()` carries blanking only, not sync position, and there is no schematic. Both pulses sit in the middle of their blanking interval | A schematic, or a measurement of the real board's composite sync | The scaler locks and the picture is centred; it affects centring, which the OSD's CRT offset also covers | latent |
| The sprite line buffer is filled one line ahead | `rtl/video/sprite_engine.sv` | The shortest latency a line-based engine can have, but the board's real latency is unknown -- MAME models none of this, so there is nothing to check it against | A photograph of the real board on a frame that moves a sprite mid-screen | `render_model.py` takes the same latency as a parameter and the two agree; at latency 0, 1, 2 and 8 the rendered frames are identical, so no capture yet distinguishes them | latent |
| The palette bank is sampled one pixel early | `rtl/video/video.sv` | The palette is looked up for pixel P+1 while P is on screen, so a bank change lands one pixel before the model puts it. Below MAME's own resolution, which is a whole scanline | Nothing needs to: the board looks the palette up at scanout too | Cost one pixel a frame when the bench indexed the bank by the displayed line instead of the fetched one | latent |
| 8253 implements modes 0 and 1 only, RW=11 binary | `rtl/sound/pit8253.sv` | The 6VB boot uses only control words 0x32, 0x70 and 0xB0; anything else asserts `unsupported` instead of being emulated | The remaining modes, the latch command and BCD counting | `sim/calib_tb` runs the whole self-calibration with `unsupported` never asserted; no game has been checked yet | latent |
| Only the lowest CEM3394 chip-select bit is acted on | `rtl/sound/sente6vb_io.sv` (`sel_first`) | The boot routine only ever raises one at a time; if a game raises several the others are dropped | Latch the control voltage into every chip whose select rises, as `chip_select_w()` does | 29,799 boot writes, never more than one bit at a time | latent |

<!-- Examples of the shape, from sibling cores:
| Sound mailbox is a stub that answers the power-on test | `rtl/gx_snd_stub.sv` | No sound CPU yet; the stub returns the reply the test expects and a heartbeat | Phase 3: the real sound board | The game's RAM check passes with it; nothing else is exercised | visible |
| Sound-command spin of 800 CPU clocks after a latch write | `rtl/cpu/…_bus.sv:NNN` | Copies MAME's 40 us wait; the real board's mechanism is unknown | A measurement of the latch on hardware | Without it the second byte overwrote the first (commit) | latent |
| Sound CPU reset held 1,024 clocks | `rtl/….sv:NNN` | MAME's pulse is zero-length; the T80 needs to see it | The measured reset length | A PCB measurement says about one second | latent |
| Screen timing from one game used for every game | `rtl/video/…crtc.sv` | MAME declares 60 Hz with no comment; the one PCB-verified rate is used for all | Per-game timing from PCB measurement | 0.043% from the verified rate | visible |
-->

## Removed

Entries move here when the hack is gone, with the commit that removed it, so a later reader can
tell "never had it" from "had it and fixed it". Delete a row once nothing else refers to it.

| What | Removed by | Replaced with |
|---|---|---|

## ~~cem3394_lpf4 misses 40 MHz at the cold corner~~ — fixed

The `tanh` table was inferred as LUTs, putting the `u_pre -> u` path 0.288 ns over at the -40 C
corner and costing most of the module's 1,669 ALMs. Moving it into `rtl/sound/tanh_lut.sv` as a
registered-read ROM, read on two consecutive cycles rather than duplicated, closed it:

| | before | after |
|---|---|---|
| ALMs | 1,669 | **827** |
| RAM blocks | 0 | **6** (30,750 bits) |
| DSP blocks | 5 | 5 |
| worst setup slack | **-0.288 ns** | **+7.985 ns** |
| Fmax | — | **61.12 MHz** |

Still bit-exact against the model: 38,400 samples, 0 mismatches.

## ~~The six-voice sound pipeline does not fit one shared instance at 40 MHz~~ — settled: two pipelines

**One 40 MHz `clk_sys` survives.** Three voices on each of two shared pipelines fits with room
to spare, so the roadmap's single-clock design decision stands and Phase 2's PLL is not
constrained by sound.

Measured, not estimated. `sim/cem3394_vco_tb` now reports the six-voice sum sample by sample --
which is what a shared pipeline has to fit, rather than six times the worst sample any one voice
ever has -- and `sim/cem3394_lpf4_tb` reports the filter's cost and checks that its best and
worst agree, which they do.

| per sample period, 6 voices | mean | worst seen | bounded worst |
|---|---|---|---|
| a musical mix of notes (the regression vectors, up to 6.9 kHz) | 297 | 543 | 606 |
| all six at 17.4 kHz, the top of the CEM3394's range | 393 | 561 | 606 |

against **417 cycles** available at 40 MHz and 96 kHz. The bound is 6 x (60 + 41): the
oscillator's worst sample is 60 cycles and the filter is a flat 41.

The oscillator's cost is data-dependent -- a polyBLEP or polyBLAMP correction only runs near a
discontinuity -- so its **mean is 8 cycles on a musical mix and 24 at the top of the range**,
against that worst case of 60. The earlier entry here reasoned from 6 x 51 + 6 x 36 = 522, six
times a worst case that a single voice reaches on a small fraction of samples, and got both the
oscillator's worst (51, now 60 with the top of the range covered) and the filter's cost (36, in
fact 41) wrong as well.

**The decision: two pipelines, three voices each.** Bounded worst 303 of 417 cycles (73%),
adversarial mean about 197 (47%), which leaves roughly 38 cycles a voice for the parts of the
chain that are not written yet -- the mixer, the VCA, the RC high-pass and the noise source.
76 of the device's 112 DSP blocks. One pipeline was rejected on the adversarial mean alone:
393 of 417 is 94% before any of that is added.

**48 kHz was rejected with a number.** Halving the rate doubles the budget to 833 cycles and
would let one pipeline fit easily, but `python scripts/cem3394_model.py rate` measures what it
costs: **-17.9 dBFS worst case, and error-to-signal of -1.0 dB at the worst operating point**,
against the fixed-point datapath's -97.8 dBFS. The CEM3394's filter reaches 54 kHz at
`filt_cv = -2` and self-oscillates there; at 48 kHz that is above Nyquist and simply cannot
happen. It is why MAME runs `va_lpf4` at `max(96000, machine rate)` whatever the machine asks
for, and the same constraint applies here.

**Still worth doing in Phase 3:** the oscillator uses 33 DSP blocks because `vco_blep` and
`vco_blamp` each have their own multiplier. Two pipelines have cycles to spare, so sharing one
between them trades headroom that exists for DSP blocks that video may want.

