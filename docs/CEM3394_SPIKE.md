# CEM3394 spike — Phase 0 criterion 5

The roadmap's gate. Criterion 5 has two halves:

1. **A CEM3394 voice reproduces MAME's model across a control-voltage sweep.**
2. **The 6VB calibration routine converges against the RTL oscillator driving 8253 counter 0.**

**Half 1 is answered, and the filter now exists in RTL and is bit-exact against the model.**
Half 2 is not started — it needs the sound Z80, the 8253 and the serial link, which is Phase 3
infrastructure. The oscillator is still model-only.

All numbers below come from `scripts/cem3394_model.py`, which is a port of MAME at commit
`5ae594ba` — `devices/sound/cem3394.cpp` plus the `va_vco`, `va_vcf`, `va_vca` and `flt_rc`
primitives it is built from. Reproduce with the commands shown; outputs land in
`debug/cem3394/`.

## The chain, and what is quantised

```
  va_vco ramp  --+
  va_vco pulse --+
  va_vco tri   --+---> va_lpf4 ---> filter_rc ---> va_vca ---> out
  mm5837 noise --+     (4-pole)     (highpass)   (final gain)
   (mixer gains)         ^
                         |
  va_vco tri --> va_vca(filt_fm) --+   filter FM, gain = mod_amount * 0.5
```

The fixed-point experiment quantises the **per-sample datapath** only: the filter's four TPT
stages and their feedback loop, the `tanh` saturator (a 1024-entry table with linear
interpolation), the AC-coupling accumulator and the output VCA. Coefficients — `g = tan(ωT/2)`,
the four `beta`, `alpha0 = 1/(1 + res·G⁴)`, the resonance and gain-compensation scales — are
computed in float and quantised once, because `fc` and `res` only change when the sound CPU
writes a control voltage. That is how the RTL will be built: a sequential coefficient unit, and
a sample loop that only multiplies and adds.

## Result 1: the control-voltage laws are exact

    python scripts/cem3394_model.py sweep

| Law | Check | Worst error |
|---|---|---|
| VCO frequency, −4 V…+4 V at 0.75 V/octave | against the datasheet's `f = 431.894 · 2^(−cv/0.75)` | **7.2 × 10⁻⁷** |
| Filter frequency, −3 V…+4 V at 0.375 V/octave | `4.3e-5 / C_vcf` = 1303.03 Hz at 0 V | exact by construction |
| Final gain, 0 V…4 V | `compute_db` / `0.891251^dB` | exact by construction |

The 7.2 × 10⁻⁷ residual is not an error in the port: the 6VB's components (R = 301 kΩ,
C = 2 nF) give a zero-CV frequency of 431.8937 Hz, and the datasheet quotes 431.894.

**Pitch through the whole chain**, measured at the output by zero crossings — the same thing
8253 counter 0 measures on the real board:

| VCO CV | nominal | measured | relative error |
|---|---|---|---|
| −2.0 | 2742.354 Hz | 2742.285 Hz | −2.5 × 10⁻⁵ |
| −1.0 | 1088.304 Hz | 1088.308 Hz | +3.7 × 10⁻⁶ |
| 0.0 | 431.894 Hz | 431.887 Hz | −1.6 × 10⁻⁵ |
| 1.0 | 171.397 Hz | 171.378 Hz | −1.1 × 10⁻⁴ |
| 3.0 | 26.993 Hz | 26.902 Hz | −3.4 × 10⁻³ |

The error grows only at the bottom of the range, where a 0.25 s measurement window holds about
seven cycles — that is the measurement, not the oscillator. **This is the number the calibration
routine depends on**, and at every frequency the 6VB would calibrate at it is within 10⁻⁴.

## Result 2: fixed point is stable everywhere, and the word width is a noise trade

    python scripts/cem3394_model.py widths --secs 0.1

60 operating points per format: VCO CV ∈ {−1, 0, 1, 2} × filter CV ∈ {−2, 0, 2} × resonance CV ∈
{0, 1, 2, 2.5, 3}. The top two resonance settings are **past the self-oscillation threshold**
(`cem3394.cpp` maps 2.5 V to a resonance gain of 4.0, where the ladder oscillates).

| Format | worst err/signal | worst err/full-scale | self-osc level error | clipped | unstable |
|---|---|---|---|---|---|
| Q4.18 / 17-bit coef | −5.7 dB | −55.1 dB | 0.54 dB | 0 | 0 |
| Q4.20 / 17 | −24.5 dB | −65.8 dB | 0.04 dB | 0 | 0 |
| Q4.22 / 18 | −39.1 dB | −85.7 dB | 0.02 dB | 0 | 0 |
| Q4.24 / 18 | −50.5 dB | −85.8 dB | 0.01 dB | 0 | 0 |
| Q4.26 / 22 | −65.5 dB | −97.8 dB | 0.00 dB | 0 | 0 |
| Q4.28 / 24 | −77.2 dB | −109.6 dB | 0.00 dB | 0 | 0 |
| Q4.30 / 26 | −90.0 dB | −122.5 dB | 0.00 dB | 0 | 0 |

**Not one format, down to 22 bits total, went unstable, saturated, or lost the
self-oscillation.** The filter's `tanh` in the feedback path is doing its job: it is there for
exactly this reason (`va_vcf.cpp`: "Saturation is required for stability at high resonance
settings"), and it bounds the fixed-point loop as well as the float one.

So the open question in the roadmap — "does a fixed-point port stay stable at high resonance" —
**is answered: yes, and not marginally.** What the word width buys is noise floor, nothing else.

Two error figures are reported because they answer different questions. `err/signal` is
misleading where the filter is nearly closed and the output is tiny; `err/full-scale` is the
audible noise floor. Above the self-oscillation threshold, float and fixed are two copies of the
same chaotic oscillator and drift apart in phase whatever the precision, so those points are
judged on staying bounded and on matching level (the "self-osc level error" column) rather than
on sample-by-sample agreement. An earlier version of this scan mixed the two regimes and
produced a non-monotonic table — more bits scoring worse — which is what prompted the split.

### Choosing a format

MiSTer's audio output is 16-bit, whose own quantisation floor is −96 dBFS. Against that:

- **Q4.24 data, 18-bit coefficients** (28-bit datapath, −85.8 dBFS) is 10 dB above the output's
  floor. 18-bit coefficients map onto a Cyclone V DSP block's 18-bit mode directly.
- **Q4.26 data, 22-bit coefficients** (30-bit datapath, −97.8 dBFS) sits at or below the
  output's floor and needs the 27-bit DSP mode.

Recommendation for the RTL: **Q4.26 / 22-bit coefficients**, because the margin costs one DSP
mode rather than more DSP blocks, and the board has DSP to spare — six voices at 96 kHz is about
12 M multiplies/s against a 40 MHz clock. Revisit if the fitter disagrees.

## Result 3: the model reproduces MAME's audio

    python scripts/mame_snd_trace.py cshift 12     # writes + MAME's own audio
    python scripts/cem3394_replay.py cshift --secs 4

`scripts/mame_snd_trace.py` records every write the 6VB's Z80 makes to the CEM3394 control
ports, timestamped, and `-wavwrite`s MAME's audio from the same run at `-samplerate 96000` —
the rate at which MAME's oscillator and filter run at the same rate, so its internal resampler
is out of the comparison. `scripts/cem3394_replay.py` reproduces the 6VB's DAC/register/chip-
select state machine, drives six model voices plus the MM5837 noise source with the same writes,
and compares.

### First, a trap that invalidated the obvious experiment

Four cartridges were captured for 10 s each and replayed. All four produced **identical numbers
to four significant figures**, which looked like a broken replay and was not. The 6VB runs its
own ROM, so its boot and self-calibration sequence is the same whatever cartridge is fitted: the
first 3 s were the same 66,882 control writes in every set, and MAME's own audio for four
different games agreed to **−112 dB** over the whole 10 s, because none of them had reached game
audio. Those runs measured the sound board booting, four times.

`sndtrace.lua` now inserts a coin and presses Start, and the replay takes `--skip` so the
comparison begins after the attract sequence while the model still runs from 0 (its state depends
on it). With a coin in, `cshift` and `snakepit` are bit-identical through boot and start, then
completely different from 10 s. The cheap check that catches this class of error: **diff the
reference captures against each other before comparing anything to them.**

### The two stimuli, and they say different things

| | boot + calibration (0–4 s) | in game (`cshift`, 10–14 s) |
|---|---|---|
| level | **+0.00 dB** | **+0.00 dB** |
| per-octave energy, 20 Hz…20 kHz | **worst band 0.01 dB** | **worst band 0.28 dB** |
| control: MAME vs a later slice of itself | 1.28 dB (113×) | **17.19 dB (61×)** |
| envelope correlation, 10 ms windows | +1.0000 | **+0.9738** |
| waveform, median error-to-signal | **−27.2 dB** | **−4.6 dB** |

**The control is what makes the spectral numbers readable.** A match means nothing until you
know what the metric can tell apart, so the script compares MAME against a later slice of itself
— same emulator, same game, different music. The model beats that by 113× and 61×. The metric is
not blind.

**Level and spectrum are right; phase is not.** On real game audio the waveform agreement is
poor, and the breakdown says why. Per 250 ms across the compared window the error runs
−13, −15, −17, −21, −14, −11, −1, −7, 0, 0, +1, −2, −2 dB: it **starts good and degrades
monotonically**. The best constant lag is 0 samples, so it is not a fixed offset — it is
accumulating divergence. That is the signature of free-running oscillators drifting apart in
phase, not of a wrong transfer function, and it is consistent with:

- **Write-time quantisation**, the largest term. 699k control writes over 20 s averages 35 kHz,
  of the same order as the 96 kHz sample rate, so several land inside one sample period. This
  replay applies them all at the sample boundary; MAME splits its stream update at the exact
  write time, so its oscillators get their new frequency a fraction of a sample earlier or later.
- **MM5837 resampling.** The noise source runs at 17,293 Hz (`mm5837.h`'s curve at Vdd = −8).
  MAME resamples it with its HQ resampler; this model holds the last value.
- `va_lpf4`'s 10⁻⁶ `machine().rand()` injection.

### What this licenses, and what it does not

Validated: the CV→parameter laws, the oscillator's waveforms and tuning, the filter's response,
the gain law, and the whole chain's spectral output and loudness envelope under real game
stimulus. That is what the RTL needs, because **the RTL is checked against this model**, not
against MAME.

Not validated, and not claimed: sample-exact agreement with MAME on free-running content. Closing
that would mean giving the replay sub-sample write scheduling, which is worth doing only if a
later comparison actually needs it.

### A version trap worth remembering

This comparison was first attempted against the MAME binary that happened to be installed, and
would have been meaningless: the CEM3394 was rewritten onto the virtual-analog primitives in
**0.289**, and 18 commits touch `cem3394.cpp` and the `va_*` files between 0.285 and 0.289. The
installed binaries were vanilla 0.285 and ARCADE 0.286 (a fork, inherited from a sibling core's
`mister.env`), against a 0.289 source tree. Diffing a port of the new model against the old
model's output would have disagreed for reasons that mean nothing. The numbers above are
`mame.exe` **0.289**, matching `MAME_SRC`. Check `<exe> -version` against
`git -C <mame tree> describe --tags` before trusting any capture.

## Result 4: the filter in RTL, bit-exact

    python scripts/cem3394_model.py vectors --data-frac 26 --coef-frac 22 --coef-int 4
    scripts/run_verilator.sh cem3394_lpf4_tb

`rtl/sound/cem3394_lpf4.sv` is the ladder as one shared multiplier over twelve cycles per
sample. `sim/cem3394_lpf4_tb` drives it with vectors the model emits — coefficients, stimulus and
expected output as integers in the datapath's own format — and compares exactly:

> **20 operating points (cutoff 200 Hz…30 kHz × resonance 0…4.8, two of them past the
> self-oscillation threshold), 1920 samples each, 38,400 samples, 0 mismatches.**

Not a tolerance. Every LSB agrees, which is the only comparison worth making between an RTL
datapath and the model that specifies it.

**It fits and it closes.** `rtl/sound/synth_check`, Quartus 17.0.2, 5CSEBA6U23I7: **827 ALMs
(2%), 5 DSP blocks (4%), 6 RAM blocks**, worst setup slack **+7.985 ns** against a 25 ns period,
**Fmax 61.12 MHz**. One voice's filter, so six cost about 5,000 ALMs and 30 DSPs — comfortable on
a part with 41,910 and 112, and the DSP count is the thing to watch when the oscillator arrives.

Getting there took two corrections worth recording, both of which the module's own comments had
claimed wrongly:

- **The multiplier was not shared.** The header said "one shared multiplier"; the code wrote the
  multiply inline in each state, inferring one per state — 35 DSP blocks for a single voice's
  filter. Muxing the operands by the step counter brought it to 5.
- **The `tanh` table was the critical path, not the multiplier.** With the table inferred as LUTs
  the -40 C corner failed by 0.288 ns. Two guesses at the path (the operand mux, then the mux
  feeding the DSP) were both wrong and the second made slack worse; `get_timing_paths` named
  `u_pre -> u` in one query. `rtl/sound/tanh_lut.sv` now holds it as a registered-read ROM, which
  halved the ALMs and turned -0.288 ns into +7.985 ns.

Two things had to be pinned down before "bit-exact" could mean anything:

- **Coefficients are not all below 1.** `res` reaches 4.8, `gain_comp` reaches 1 + 0.2·4.8 =
  1.96, and `alpha0` is exactly 1.0 with no resonance. A format with only a sign bit of integer
  range wraps 1.0 to −1.0, which is what the first run did. Both sides now carry an explicit
  `CW_INT`, the model reports any coefficient that does not fit instead of silently clamping,
  and the vector header records the format so the bench refuses to run against a mismatched one.
- **`tanh` is now specified as hardware does it**: a shift for the table index, an unsigned
  interpolation fraction of defined width, round-half-up on the product. The model emits the
  table the RTL reads, so there is one definition of it and the two cannot drift apart.

## Result 5: the oscillator in RTL, bit-exact, and the six-voice budget

    python scripts/cem3394_model.py vectors --data-frac 26 --coef-frac 22 --coef-int 4
    scripts/run_verilator.sh cem3394_vco_tb

`rtl/sound/cem3394_vco.sv`, with `vco_blep.sv` and `vco_blamp.sv` as the two anti-aliasing
kernels. Six oscillator settings — near-Nyquist, an exact divisor, awkward ratios, two pulse
widths — 1920 samples each:

> **11,520 samples, 0 mismatches, worst 51 cycles per sample.**

Two bugs were found by the bench and both were mine, not the model's: `naive_ramp` shifted one
place too far (the 34-bit concatenation computed `(2p - 2·2^32) >> 7` instead of `(2p - 2^32) >> 6`),
and the "just before a discontinuity" delta was written as `{1'b1, x} - 2^32`, which cancels back
to `x` — the value wanted is simply `{1'b1, x}` read as a signed 33-bit number.

It closes timing: **1,099 ALMs, 33 DSP blocks, +9.468 ns worst setup slack**.

### The budget, which does not close as first assumed

33 DSP blocks is for **one** oscillator. The plan was always to time-share one pipeline across
the six voices rather than instantiate six, so the DSP count is not multiplied — but the
*cycles* are, and that is what does not fit:

| | cycles/sample | ×6 voices |
|---|---|---|
| oscillator | 51 (measured) | 306 |
| filter | 36 | 216 |
| **total** | 87 | **522** |

A 96 kHz sample is **417** `clk_sys` cycles at 40 MHz. One shared pipeline of each needs 522.

| option | cycles | DSP | |
|---|---|---|---|
| 1 pipeline each at 40 MHz | 522 | 38 | **does not fit** |
| 2 pipelines each | 261 | 76 | fits, 68% of the DSPs |
| 1 pipeline each at 50 MHz+ | 417 | 38 | fits, needs a second clock domain |

This corrects the estimate in "Cost estimate" above, which counted **multiplies** (about 38 per
sample, 55% of one multiplier) and not **cycles**. The sequential kernels spend more cycles than
they do multiplies — `vco_blamp` takes 13 cycles for 9 multiplies — so the multiply count was
the wrong budget to reason about. The roadmap's "one 40 MHz `clk_sys`, every clock enable a
counter tap" decision needs an amendment for the sound path, and which way to go is a Phase 3
decision with these numbers in hand rather than something to settle now.

The 33 DSP blocks are also worth revisiting: `vco_blep` and `vco_blamp` each hold their own
multiplier and the operands are wide (32×32, 34×34), so each multiply costs several DSPs.
Sharing one multiplier between the two kernels would cut that substantially at the price of
more cycles — the opposite trade to the one above, and they interact.

## Result 6: the calibration loop, decoded and predicted

    python scripts/mame_boot_trace.py cshift 40000 --cpu :audio6vb:audiocpu         --space io --addr-hi 0xff --tag sente6vb_io

Tracing the 6VB's **I/O** space (the program-space trace does not see it) shows exactly what the
self-calibration does, and it is simpler than expected.

Boot programs the 8253 — `0x32` to counter 0 (mode 1, one-shot, LSB then MSB), `0x70` and `0xB0`
to counters 1 and 2 (mode 0) — then writes all eight control registers of all six chips. After
that the pattern repeats 6,087 times: write the 12-bit DAC (ports 0x0A/0x0B), select a register
(0x0C), pulse the chip select `0xFE` then `0xFF` so the value latches on the rising edge, then
poll port 0x08 (9,039 reads) and finally read counter 1 (ports 0x00/0x01, 60 reads — 30
measurements, LSB then MSB).

**Counter 0 is programmed to span exactly one period of the voice oscillator clocking its
flip-flop, gating counter 1, which counts down from 0xFFFF at 2 MHz** (8 MHz / 4,
`sente6vb.cpp:125`). So the routine measures an oscillator period in 2 MHz ticks:

> `counter1 = 0xFFFF - round(2e6 / f_vco)`

Checked against the reconstructed DAC values in MAME's own trace, for the first voice's
register-0 sweep — which is a **binary search**, the CV stepping −0.002, +0.998, +1.248, +1.279,
+1.295, halving each time:

| VCO CV | f | predicted count | MAME read | Δ |
|---|---|---|---|---|
| −0.002 | 432.693 Hz | 60913 | 60913 | 0 |
| +0.998 | 171.714 Hz | 53888 | 53888 | 0 |
| +1.248 | 136.290 Hz | 50860 | 50860 | 0 |
| +1.279 | 132.440 Hz | 50434 | 50431 | 3 |
| +1.295 | 130.496 Hz | 50209 | 50211 | −2 |

Exact on three points and within 3 counts of 65,535 on the other two.

**And the RTL oscillator gives the same counts.** Feeding its Q0.32 quantised frequency through
the same formula reproduces MAME's readings to within 3 counts — 0.005%, far inside the binary
search's step at every iteration:

| VCO CV | MAME | RTL | Δ |
|---|---|---|---|
| −0.002 | 60913 | 60913 | 0 |
| +0.998 | 53888 | 53888 | 0 |
| +1.248 | 50860 | 50860 | 0 |
| +1.279 | 50431 | 50434 | +3 |
| +1.295 | 50211 | 50209 | −2 |

**What this establishes, and what it does not.** It establishes that the quantity the calibration
routine measures is the same under the RTL oscillator as under MAME, so the search will take the
same path and converge on the same CV. It does **not** run the routine: the 8253, the counter-0
flip-flop and the I/O decode are not written yet, and until they are, criterion 5's second half
is *predicted to pass with the mechanism quantified*, not met. What is no longer needed is a
guess — the bench to build is now fully specified, and its expected output is a formula.

## What is not done

- **Nothing in RTL.** The model is the specification the RTL will be written against; the RTL is
  then checked against the model, per WORKFLOW section 9.
- **Only one game has been replayed in-game.** `snakepit` was captured with a coin too but is
  silent over the window compared, so the in-game column above is Chicken Shift alone. Pick
  windows with audio in `snakepit`, `gimeabrk` and `nametune` before treating Result 3 as
  covering high resonance, heavy noise mixing and filter FM.
- **The calibration loop.** Half 2 of the criterion. Needs the sound Z80, the 8253 and the
  serial link.
- **The VCO datapath is still float in the fixed-point mode.** It is an accumulator plus
  polynomial corrections and cannot go unstable, but its quantisation will set the waveform
  noise floor and has not been measured.
