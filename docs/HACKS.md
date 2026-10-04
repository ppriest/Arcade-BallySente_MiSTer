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
| Flip screen is the core's, not the board's | `rtl/video/video.sv` (`flip_f`, `bank_row`); the fake DIP in `scripts/build_mra.py` | No set has a flip, so there is no reference. The picture is read mirrored and the sprite engine draws the mirrored line. The palette bank, which programs change by beam time, is recorded per row and replayed mirrored: rows the beam has not reached yet this frame take last frame's bank, and a video RAM write lands where the flipped beam happens to be, not where it would be on an unflipped board | Nothing for the geometry: no board flips to compare with. Exact bank and write timing would need the whole frame buffered, which this core does not have | `sim/video_tb` on six beam captures with the writes off: flipped equals the unflipped frame turned 180 degrees, 0 of 61,440 pixels differ in each. With writes and bank changes, unverified | visible |
| `inv_step` saturates below about 23 Hz | `rtl/sound/sente6vb_params.sv`, `scripts/cem3394_params.py` `inv_step_of_dac` | The oscillator's 1/step is Q12.20 in 32 bits; below 23 Hz (DAC above ~3650) it needs a 33rd bit and is clamped, so the polyBLEP/polyBLAMP corrections there are too small | A wider `inv_step` through `cem3394_vco`'s kernels | No traced game goes below 27.5 Hz (cshift, snakepit, gimeabrk, nametune: lowest VCO DAC 3574) | latent |
| Analog ports from MiSTer's devices by a fixed rule | `rtl/analog_inputs.sv` | MAME maps any host device to a port with sensitivity and key speed the user can change; here player 1's trackball and dial are the mouse, any player's the stick as a rate (past 16, an eighth of the deflection a frame) and the d-pad at 10 a frame, half MAME's PORT_KEYDELTA(20), which was reported too fast in Snacks'n Jaxson, dials also the spinner, and the scale is one mouse count per port unit. The feel is chosen, not measured | Per-set scale from play on hardware, or an OSD sensitivity option | `sim/analog_tb` checks the rule as written; how it plays is unverified | visible |
| The sound is 18 dB louder than MAME's | `rtl/balsente_core.sv` (`snd_gain`) | MAME's mix peaks near -20 dBFS in every game recorded (cshift, snakepit, gimeabrk, nametune) and was reported inaudible under a MiSTer's noise floor. The output is multiplied by 8 and saturates, so a game louder than those recorded clips | The real board's line level, from a recording of one | Peaks of the recordings in `debug/*-snd`; after the gain, cshift's in-game peak is about -2 dBFS. Clipping in other games unverified | visible |
| Grudge Match's wheels move a step at a time | `rtl/grudge_wheels.sv` | MAME's wheels are dials at sensitivity 50, read four times a frame with interpolation; the game sees only which way each moved (`grudge_steering.sv`). Here the mouse and spinners add their counts as they arrive, and a d-pad or stick adds one step every 16 lines, so a held direction registers at every interrupt | A feel tuned on hardware | `sim/board_tb` against MAME with the wheel positions forced (mame_input_trace.py); the MiSTer device mapping unverified | visible |
| Stompin's pads are the d-pad's directions | `rtl/analog_inputs.sv` (kind 6) | The cabinet has eight separate pads; a d-pad can press at most two neighbouring ones at once, as a diagonal, never two opposite ones | Eight buttons mapped to the pads | unverified on hardware | visible |
| Night Stocker's gun position | `rtl/lightgun.sv` | A light gun reads where the beam is; this is MAME's FAKEX/FAKEY, moved by the mouse, d-pad or stick as the Seta core's Zombie Raid does, with the crosshair at row y - 16 (Y a raster line, 16 blanked lines above row 0), where the game lands the shot; MAME's crosshair spreads 0-255 over the 240 visible rows and sits 16 lines below it | A MiSTer light gun (Sinden or similar) read against the beam | the gun bits against MAME with the position forced (mame_input_trace.py); aim unverified on hardware | visible |
| Shrike Avenger's 68000 runs at 8 MHz on average, not evenly | `rtl/shrike_board.sv` (`acc`) | FX68K takes two phase enables per clock; 16 MHz of them from 40 MHz come every 2 or 3 clocks, so its bus cycles are 8 MHz on average but jitter by a 40 MHz clock | A clock the PLL divides evenly, if a Shrike-only build is ever worth one | MAME schedules the two CPUs in 1/6000 s slices, so no finer relationship is specified | latent |
| Shrike Avenger's two seat buttons are one Start | `scripts/build_mra.py` (`seats`) | The cabinet's seat has two start buttons, MAME's START1 and START2, which the game wants pressed together (misteraddons' notes); both are mapped to Start, so they cannot be pressed apart | Nothing, unless a game state is found that wants one alone | unverified here | latent |
| Shrike Avenger's carpet switch is left released | `scripts/build_mra.py` (`P1_BUTTON5`) | MAME's Button 5, a switch under the cabinet's carpet, reads released; misteraddons report the game plays so | A button for it, if anything is found that needs it | unverified here | latent |
| The ADC's raw mode reads 0 on channels 4-7 | `rtl/adc.sv` (`raw`) | MAME's shift-32 case indexes its four-entry port array with the channel, so channels 4-7 read past the array (`balsente_m.cpp` `adc_finished`). Stompin', the one supported set in raw mode, selects channels 0-3 only | What Shrike Avenger reads there, if it is ever supported | `debug/adc/stompin_adc.vec`: 3,982 selects in 600 frames, none of 4-7 | latent |
| Each X2212 NOVRAM is one array: no separate EEPROM, recall not wired | `rtl/game_board.sv` (`nv`) | The chip has a live SRAM and a shadow EEPROM; RECALL (output latch bit 7, `nvrecall_w`) copies EEPROM into SRAM. Here the SRAM is the only copy and starts at MAME's blank EEPROM value, 0xF | A second array per chip loaded from the save file, copied on recall; STORE at the save point | `cshift` never writes 0x980E/0x980F in 700 frames of MAME trace, so recall happens only at reset, where the two are the same | latent |

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
| The main board's ACIA has nothing on the other end | the commit adding `rtl/sound/sente6vb.sv` | the 6VB's digital side on the link |
| Only the lowest CEM3394 chip-select bit is acted on | the same commit | `sente6vb_io.cv_mask`, every chip whose select rises; `cv_chip` stays for `sim/calib_tb`'s single-voice model |

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

