# CEM3394 spike — Phase 0 criterion 5

The roadmap's gate. Criterion 5 has two halves:

1. **A CEM3394 voice reproduces MAME's model across a control-voltage sweep.**
2. **The 6VB calibration routine converges against the RTL oscillator driving 8253 counter 0.**

**Half 1 is answered in the software model. Half 2 is not started** — it needs the sound Z80,
the 8253 and the serial link, which is Phase 3 infrastructure. Nothing here has been written in
RTL yet.

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

Chicken Shift, 330,324 control writes over 12 s, first 4 s compared:

| | |
|---|---|
| level | **+0.00 dB** against MAME |
| per-octave energy, 20 Hz…20 kHz, both normalised to equal RMS | **worst band 0.01 dB** |
| envelope correlation, 10 ms windows | **+1.0000** |
| waveform, median over non-silent 100 ms windows | **−27.2 dB** error-to-signal |

**The control matters more than the numbers.** A spectral match means nothing until you know
what the metric can tell apart, so the script also compares MAME against a later slice of
itself — same emulator, same game, different music. That scores **1.28 dB**, 113× the model's
0.01 dB. The metric is not blind; the model really is tracking MAME.

The −27.2 dB waveform residual is spread across the run (the worst 5% of windows hold 27% of
the error energy, so it is not one bad transient) and is consistent with timing, not structure:

- **Write-time quantisation.** 330k writes over 12 s averages 27.5 kHz, of the same order as the
  96 kHz sample rate, so several control writes often land inside one sample period. This replay
  applies them all before the sample; MAME splits its stream update at the exact write time.
  This is the largest term and the one worth attacking if the residual ever matters.
- **MM5837 resampling.** The noise source runs at 17,293 Hz (`mm5837.h`'s curve at Vdd = −8).
  MAME resamples it with its HQ resampler; this model holds the last value.
- `va_lpf4`'s 10⁻⁶ `machine().rand()` injection.

None of these is a difference in the chain being modelled, and none would be reproduced by the
RTL either — the RTL will be checked against the model, which is now anchored to MAME.

### A version trap worth remembering

This comparison was first attempted against the MAME binary that happened to be installed, and
would have been meaningless: the CEM3394 was rewritten onto the virtual-analog primitives in
**0.289**, and 18 commits touch `cem3394.cpp` and the `va_*` files between 0.285 and 0.289. The
installed binaries were vanilla 0.285 and ARCADE 0.286 (a fork, inherited from a sibling core's
`mister.env`), against a 0.289 source tree. Diffing a port of the new model against the old
model's output would have disagreed for reasons that mean nothing. The numbers above are
`mame.exe` **0.289**, matching `MAME_SRC`. Check `<exe> -version` against
`git -C <mame tree> describe --tags` before trusting any capture.

## What is not done

- **Nothing in RTL.** The model is the specification the RTL will be written against; the RTL is
  then checked against the model, per WORKFLOW section 9.
- **Only one game has been replayed.** Chicken Shift exercises the voices but not necessarily
  every corner — high resonance, heavy noise mixing, filter FM. Run the replay over `snakepit`,
  `gimeabrk` and `nametune` before treating Result 3 as covering the device.
- **The calibration loop.** Half 2 of the criterion. Needs the sound Z80, the 8253 and the
  serial link.
- **The VCO datapath is still float in the fixed-point mode.** It is an accumulator plus
  polynomial corrections and cannot go unstable, but its quantisation will set the waveform
  noise floor and has not been measured.
