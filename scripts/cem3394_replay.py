#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive the software model with MAME's own control writes, and compare the audio.

    python scripts/mame_snd_trace.py cshift 12      # capture writes + MAME's wav
    python scripts/cem3394_replay.py cshift         # replay and compare

WORKFLOW section 9: the model is checked against MAME before the RTL is checked
against the model. This is that check.

The 6VB's register state machine is reproduced exactly as `sente6vb.cpp` has it:
port 0x0a/0x0b assemble a 12-bit DAC value, 0x0c selects one of eight control
registers, and a write to 0x0e latches the DAC value into that register for every
chip whose enable bit GOES HIGH. A DAC write while any chip is already selected
re-latches, which `dac_data_w()` does by toggling chip select off and back on.

WHAT THIS CAN AND CANNOT SHOW

Sample-for-sample agreement is not available, and chasing it would be a mistake:

  * MAME's MM5837 noise source runs at 17293 Hz (`mm5837.h` frequency curve at
    Vdd = -8) and MAME resamples it to the filter's rate with its own HQ
    resampler. This model holds the last value instead, so any voice mixing in
    external input differs in high-frequency content.
  * `va_lpf4` adds 1e-6 of `machine().rand()` to its input every sample.
  * Past the resonance threshold a voice is an oscillator, and two copies drift
    apart in phase from any difference at all.

So the bar is level and spectrum, not a diff: overall RMS, per-octave band
energy, and the correlation of the two envelopes.
"""
import argparse
import math
import struct
import sys
import wave
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from cem3394_model import CEM3394, RCHighpass  # noqa: E402

# sente6vb.cpp device_add_mconfig(): noise.set_vdd(-8.0), then a high-pass made
# of R19 + R20 = 68k + 1k and C115 = 2.2uF before it reaches the voices.
NOISE_VDD = -8.0
NOISE_R = 68e3 + 1e3
NOISE_C = 2.2e-6
# Each cem3394 adds its route to "mono" at 0.50.
VOICE_MIX = 0.50


def mm5837_frequency(vdd):
    """mm5837.h frequency(), including its x2."""
    r = 191.98 * vdd ** 3 + 5448.4 * vdd ** 2 + 43388 * vdd + 105347
    return max(100.0, r * 2.0)


class MM5837:
    """17-bit shift register, 1.0 or 0.0 per clock (mm5837.h)."""

    def __init__(self):
        self.shift = 0x1ffff

    def clock(self):
        tap14 = (self.shift >> 13) & 1
        tap17 = (self.shift >> 16) & 1
        zero = 1 if self.shift == 0 else 0
        self.shift = ((self.shift << 1) | (tap14 ^ tap17 ^ zero)) & 0x3ffff
        return (self.shift >> 16) & 1


class Sente6VB:
    """The register state machine in front of the six voices."""

    def __init__(self, rate):
        self.dac_value = 0
        self.dac_register = 0
        self.chip_select = 0x3f
        self.voices = [CEM3394(rate) for _ in range(6)]

    def _chip_select_w(self, data):
        voltage = CEM3394.dac_to_cv(self.dac_value)
        diff = data ^ self.chip_select
        self.chip_select = data
        for i in range(6):
            if (diff & (1 << i)) and (data & (1 << i)):
                self.voices[i].set_cv(self.dac_register, voltage)

    def write(self, port, data):
        if port in (0x0a, 0x0b):
            if port & 1:
                self.dac_value = (self.dac_value & 0xfc0) | ((data >> 2) & 0x03f)
            else:
                self.dac_value = (self.dac_value & 0x03f) | ((data << 6) & 0xfc0)
            if (self.chip_select & 0x3f) != 0x3f:
                keep = self.chip_select
                self._chip_select_w(0x3f)
                self._chip_select_w(keep)
        elif port in (0x0c, 0x0d):
            self.dac_register = data & 7
        elif port in (0x0e, 0x0f):
            self._chip_select_w(data)
        # 0x08/0x09 is the counter control; bit 0 is an audio enable that
        # sente6vb.cpp does not act on, so it is ignored here too.


def load_trace(path):
    rows = []
    for ln in open(path, encoding="utf8"):
        if ln.startswith("#") or not ln.strip():
            continue
        t, port, data = ln.split()
        rows.append((float(t), int(port, 16), int(data, 16)))
    return rows


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width != 2:
        sys.exit(f"{path}: expected 16-bit samples, got {width * 8}-bit")
    a = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)
    return a, rate


def band_energy(x, rate, edges):
    """Energy per octave band, in dB, from one Welch-style average."""
    n = 8192
    if len(x) < n:
        return [float("nan")] * (len(edges) - 1)
    acc = np.zeros(n // 2 + 1)
    hop = n // 2
    win = np.hanning(n)
    count = 0
    for i in range(0, len(x) - n, hop):
        acc += np.abs(np.fft.rfft(x[i:i + n] * win)) ** 2
        count += 1
    acc /= max(1, count)
    freqs = np.fft.rfftfreq(n, 1.0 / rate)
    out = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        m = (freqs >= lo) & (freqs < hi)
        e = acc[m].sum()
        out.append(10.0 * math.log10(e) if e > 0 else -999.0)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--rate", type=int, default=96000)
    ap.add_argument("--secs", type=float, default=None,
                    help="how much to replay; default the whole trace")
    a = ap.parse_args()

    base = REPO / "debug" / f"{a.game}-snd"
    trace = base / f"{a.game}_snd.trace"
    ref_wav = base / f"{a.game}.wav"
    if not trace.exists():
        sys.exit(f"no {trace}; run scripts/mame_snd_trace.py {a.game} first")

    rows = load_trace(trace)
    if not rows:
        sys.exit("the trace is empty")
    end = a.secs if a.secs is not None else rows[-1][0]
    n = int(end * a.rate)
    print(f"{len(rows)} control writes over {rows[-1][0]:.3f}s; replaying {end:.3f}s "
          f"at {a.rate} Hz")

    board = Sente6VB(a.rate)
    noise_src = MM5837()
    noise_hp = RCHighpass(a.rate, NOISE_R, NOISE_C)
    noise_step = mm5837_frequency(NOISE_VDD) / a.rate
    noise_phase = 0.0
    noise_level = 0.0

    out = np.zeros(n, dtype=np.float64)
    ri = 0
    for i in range(n):
        t = i / a.rate
        while ri < len(rows) and rows[ri][0] <= t:
            board.write(rows[ri][1], rows[ri][2])
            ri += 1
        noise_phase += noise_step
        while noise_phase >= 1.0:
            noise_level = float(noise_src.clock())
            noise_phase -= 1.0
        ext = noise_hp.process(noise_level)
        out[i] = sum(v.sample(ext) for v in board.voices) * VOICE_MIX

    model_wav = base / f"{a.game}_model.wav"
    peak = float(np.max(np.abs(out))) or 1.0
    pcm = np.clip(out / max(1.0, peak) * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(str(model_wav), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(a.rate)
        w.writeframes(pcm.tobytes())
    print(f"model peak {peak:.4f}, RMS {float(np.sqrt((out ** 2).mean())):.5f} -> {model_wav}")

    if not ref_wav.exists():
        print(f"no {ref_wav} to compare against")
        return 0
    ref, ref_rate = read_wav(ref_wav)
    print(f"MAME  {len(ref)} samples at {ref_rate} Hz, RMS {float(np.sqrt((ref ** 2).mean())):.5f}")
    if ref_rate != a.rate:
        print(f"NOTE  rate mismatch ({ref_rate} vs {a.rate}); compare on level only")
        return 0

    full_ref = ref
    m = min(len(ref), len(out))
    ref, mod = ref[:m], out[:m]
    r_rms, m_rms = float(np.sqrt((ref ** 2).mean())), float(np.sqrt((mod ** 2).mean()))
    if r_rms <= 0 or m_rms <= 0:
        print("one side is silent; nothing to compare")
        return 1
    print(f"\nlevel     model is {20 * math.log10(m_rms / r_rms):+.2f} dB against MAME")

    edges = [20, 80, 160, 320, 640, 1280, 2560, 5120, 10240, 20480]
    be_r = band_energy(ref / r_rms, a.rate, edges)
    be_m = band_energy(mod / m_rms, a.rate, edges)
    print("\nper-octave energy, both normalised to equal RMS:")
    print(f"  {'band':>14} {'MAME':>9} {'model':>9} {'diff':>8}")
    worst = 0.0
    for lo, hi, r, mo in zip(edges[:-1], edges[1:], be_r, be_m):
        d = mo - r
        if math.isfinite(d):
            worst = max(worst, abs(d))
        print(f"  {f'{lo}-{hi} Hz':>14} {r:>8.2f}dB {mo:>8.2f}dB {d:>+7.2f}dB")
    print(f"worst band difference {worst:.2f} dB")

    # A spectral match means nothing without knowing what the metric can tell
    # apart. MAME against a LATER SLICE OF ITSELF is the control: same emulator,
    # same game, different music. If the model does not beat that comfortably,
    # the agreement above is the metric being blind, not the model being right.
    if len(full_ref) >= 2 * m:
        ctl = full_ref[m:2 * m]
        c_rms = float(np.sqrt((ctl ** 2).mean()))
        if c_rms > 0:
            be_c = band_energy(ctl / c_rms, a.rate, edges)
            cw = max(abs(c - r) for c, r in zip(be_c, be_r)
                     if math.isfinite(c) and math.isfinite(r))
            print(f"control   MAME against a later slice of itself: {cw:.2f} dB "
                  f"({cw / worst:.0f}x the model's difference)" if worst > 0 else
                  f"control   MAME against a later slice of itself: {cw:.2f} dB")

    # Waveform agreement, per 100 ms window. Silent windows are excluded: an
    # error-to-signal ratio of 0/0 reports as 0 dB and would dominate the worst
    # case while meaning nothing.
    win = a.rate // 10
    k = m // win
    if k:
        R = ref[:k * win].reshape(k, win)
        M = mod[:k * win].reshape(k, win)
        sig = np.sqrt((R ** 2).mean(axis=1))
        err = np.sqrt(((R - M) ** 2).mean(axis=1))
        live = sig > 1e-6
        if live.any():
            db = 20 * np.log10(err[live] / sig[live])
            e = ((R - M) ** 2).sum(axis=1)
            top = max(1, k // 20)
            share = 100.0 * e[np.argsort(e)[::-1][:top]].sum() / max(e.sum(), 1e-30)
            print(f"\nwaveform  median error-to-signal {float(np.median(db)):.1f} dB over "
                  f"{int(live.sum())} non-silent 100 ms windows "
                  f"(worst {float(db.max()):.1f} dB)")
            print(f"          worst 5% of windows hold {share:.0f}% of the error energy "
                  f"-- spread, not one transient" if share < 50 else
                  f"          worst 5% of windows hold {share:.0f}% of the error energy "
                  f"-- concentrated; look at those")

    # Envelope: phase may differ, loudness over time should not.
    ewin = a.rate // 100
    def env(x):
        n_ = len(x) // ewin
        return np.sqrt((x[:n_ * ewin].reshape(n_, ewin) ** 2).mean(axis=1))
    er, em = env(ref), env(mod)
    if er.std() > 0 and em.std() > 0:
        print(f"envelope  correlation over 10 ms windows {float(np.corrcoef(er, em)[0, 1]):+.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
