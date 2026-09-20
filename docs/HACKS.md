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
| {{ONE_LINE_WHAT}} | `{{FILE}}:{{LINE}}` | {{WHY}} | {{FIX}} | {{EVIDENCE}} | {{SEVERITY}} |

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

## The six-voice sound pipeline does not fit one shared instance at 40 MHz

Measured, not estimated: the oscillator takes 51 `clk_sys` cycles per sample (worst case, from
`sim/cem3394_vco_tb`) and the filter 36. Six voices through one shared pipeline of each is 522
cycles, against the 417 a 96 kHz sample has at 40 MHz.

Options, with real numbers: two pipelines of each (261 cycles, 76 of 112 DSP blocks), or one of
each on an audio clock of 50 MHz or more (38 DSP, a second clock domain). Sharing one multiplier
between `vco_blep` and `vco_blamp` would cut the 33 DSP blocks the oscillator currently uses, at
the cost of more cycles — which pushes the other way.

**What would settle it:** a Phase 3 decision once the rest of the sound board exists and its own
cycle cost is known. Recorded here because the roadmap's "one 40 MHz `clk_sys`" design decision
does not survive this subsystem unchanged, and because the earlier estimate in the spike document
reasoned about multiply counts rather than cycles and so got it wrong.
