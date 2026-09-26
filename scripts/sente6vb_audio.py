#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The 6VB's audio in integers: the specification the sound RTL implements.

    python scripts/sente6vb_audio.py replay cshift --secs 12 --skip 9
    python scripts/sente6vb_audio.py replay cshift --secs 12 --skip 9 --float

`replay` drives six voices with the control writes MAME's 6VB made
(scripts/mame_snd_trace.py) and compares the result with MAME's own audio,
using scripts/cem3394_replay.py's metrics. `--float` runs that script's
floating-point model instead, as the control.

Per voice, in the order the RTL runs it, every value an integer:

    oscillator   VCOFixed (scripts/cem3394_model.py): ramp, pulse, triangle, Q4.26
    mixer        sum of waveform x gain, exact, rounded once to Q4.26
    coefficients scripts/cem3394_coef.py, from the base cutoff, the FM depth and
                 this sample's triangle
    filter       va_lpf4 in Q4.26 data and Q4.22 coefficients, round-half-up and
                 saturation after every operation (rtl/sound/cem3394_lpf4.sv)
    AC coupling  flt_rc high-pass, 11k and 10uF, accumulator 12 bits wider
    final gain   Q1.26, then the audio-enable bit, counter control bit 0. The
                 6VB program holds it low through its boot calibration and sets
                 it at 9.47 s in every traced game, so the voices are muted
                 while they are measured. MAME applies the bit only when it
                 CHANGES and starts every voice at gain 1, so its calibration
                 is audible (docs/MAME_KLUDGES.md). The core follows the bit;
                 `mame_enable=True` reproduces MAME's behaviour for comparing
                 with its recordings.

and for the board: the MM5837 at 17.3 kHz through its own high-pass (68k+1k,
2.2uF) into every voice's external input, and the six voices at 0.5 each.
Output is 16-bit, the value x 32768 clamped, as MAME writes it.
"""
import argparse
import math
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import cem3394_coef as coef            # noqa: E402
import cem3394_params as prm           # noqa: E402
from cem3394_model import VCOFixed     # noqa: E402

SR = 96000
DF = 26                               # data fraction, Q4.26
CF = 22                               # coefficient fraction, Q4.22
DMAX = (1 << (4 + DF - 1)) - 1
DMIN = -(1 << (4 + DF - 1))
TANH_LOG2N = 10
HP_EXTRA = 12


def rnd(x, sh):
    return (x + (1 << (sh - 1))) >> sh if sh > 0 else x << (-sh)


def sat(x):
    return DMAX if x > DMAX else DMIN if x < DMIN else x


def cmul(c, d):
    """coefficient (Q4.22) x data (Q4.26) -> data, rounded and saturated."""
    return sat(rnd(c * d, CF))


TANH_SHIFT = DF + 2 - TANH_LOG2N
TANH_N = 1 << TANH_LOG2N
# As TanhLUT builds it: each entry the data-format quantisation of tanh.
TANH_TAB = [sat(math.floor(math.tanh(i * 4.0 / TANH_N) * (1 << DF) + 0.5)) for i in range(TANH_N + 1)]


def tanh_q(u):
    a = -u if u < 0 else u
    if a >= TANH_N << TANH_SHIFT:
        y = TANH_TAB[TANH_N]
    else:
        i = a >> TANH_SHIFT
        fr = a & ((1 << TANH_SHIFT) - 1)
        y = TANH_TAB[i] + ((TANH_TAB[i + 1] - TANH_TAB[i]) * fr + (1 << (TANH_SHIFT - 1)) >> TANH_SHIFT)
    return -y if u < 0 else y


def hp_k(r, c):
    return round((1.0 - math.exp(-1.0 / (r * c) / SR)) * (1 << CF))


class HighPass:
    """flt_rc HIGHPASS in integers: y = x - mem, mem += (x - mem) k."""

    def __init__(self, r, c):
        self.k = hp_k(r, c)
        self.acc = 0                          # mem, with DF + HP_EXTRA fraction bits

    def process(self, x):
        d = (x << HP_EXTRA) - self.acc
        y = sat(rnd(d, HP_EXTRA))
        self.acc += rnd(d * self.k, CF)
        return y


class Voice:
    def __init__(self):
        self.dac = [2048] * 8                 # cem3394 device_reset: every CV 0 V
        self.vco = VCOFixed(SR)
        self.st = [0, 0, 0, 0]
        self.ac = HighPass(11e3, 10e-6)
        self._cache = None
        for reg in range(8):
            self.set(reg, 2048)

    def set(self, reg, dac):
        self.dac[reg] = dac
        d = self.dac
        self.vco.step = prm.step_of_dac(d[0])
        self.vco.inv_step = prm.inv_step_of_dac(d[0])
        self.vco.pw = prm.pw_of_dac(d[6])
        tri, saw = prm.wave_of_dac(d[7])
        self.g_pulse, self.g_saw, self.g_tri, self.g_ext, self.g_final = \
            prm.gains_of(d[4], d[1], tri, saw)
        self.base = prm.base_of_dac(d[3])
        self.mod_half = prm.mod_half_of_dac(d[5])
        self.res = prm.res_of_dac(d[2])
        self.gcomp = prm.gcomp_of_res(self.res)
        self._cache = None

    def sample(self, ext):
        ramp, pulse, tri = self.vco.step_sample()
        mix = sat(rnd(ramp * self.g_saw + pulse * self.g_pulse + tri * self.g_tri
                      + ext * self.g_ext, DF))
        # coefficients: every sample under FM, else once per parameter change
        if self.mod_half:
            am, ae = coef.modulate(*self.base, self.mod_half, tri)
            c = coef.coeffs(am, ae, self.res)
        else:
            if self._cache is None:
                self._cache = coef.coeffs(*self.base, self.res)
            c = self._cache
        alpha, b0, b1, b2, b3, alpha0 = c
        # va_lpf4, as rtl/sound/cem3394_lpf4.sv computes it
        sigma = 0
        for b, s in zip((b0, b1, b2, b3), self.st):
            sigma = sat(sigma + cmul(b, s))
        x = cmul(self.gcomp, mix)
        u = cmul(alpha0, sat(x - cmul(self.res, sigma)))
        u = tanh_q(u)
        for i in range(4):
            vn = cmul(alpha, sat(u - self.st[i]))
            u = sat(vn + self.st[i])
            self.st[i] = sat(vn + u)
        y = self.ac.process(u)
        return sat(rnd(y * self.g_final, DF))


class Board:
    """The DAC/register/chip-select latch, six voices, noise, the mix."""

    NOISE_HZ = None

    def __init__(self, mame_enable=False):
        from cem3394_replay import mm5837_frequency, NOISE_VDD, NOISE_R, NOISE_C
        self.mame_enable = mame_enable
        self.ctrl_bit0 = 0
        self.voices = [Voice() for _ in range(6)]
        self.dac_value = 0
        self.dac_register = 0
        self.chip_select = 0x3f
        self.audio_en = 1 if mame_enable else 0
        self.lfsr = 0x1ffff
        self.noise_bit = 0
        self.noise_acc = 0
        self.noise_step = round(mm5837_frequency(NOISE_VDD) / SR * (1 << 32))
        self.noise_hp = HighPass(NOISE_R, NOISE_C)

    def _cs(self, data):
        diff = data ^ self.chip_select
        self.chip_select = data
        for i in range(6):
            if (diff >> i) & 1 and (data >> i) & 1:
                self.voices[i].set(self.dac_register, self.dac_value)

    def write(self, port, data):
        if port in (0x08, 0x09):
            if not self.mame_enable or (data & 1) != self.ctrl_bit0:
                self.audio_en = data & 1
            self.ctrl_bit0 = data & 1
        elif port in (0x0a, 0x0b):
            if port & 1:
                self.dac_value = (self.dac_value & 0xfc0) | ((data >> 2) & 0x03f)
            else:
                self.dac_value = (self.dac_value & 0x03f) | ((data << 6) & 0xfc0)
            if (self.chip_select & 0x3f) != 0x3f:
                keep = self.chip_select
                self._cs(0x3f)
                self._cs(keep)
        elif port in (0x0c, 0x0d):
            self.dac_register = data & 7
        elif port in (0x0e, 0x0f):
            self._cs(data)

    def _noise(self):
        self.noise_acc += self.noise_step
        while self.noise_acc >= 1 << 32:
            self.noise_acc -= 1 << 32
            s = self.lfsr
            t = ((s >> 13) ^ (s >> 16) ^ (1 if s == 0 else 0)) & 1
            self.lfsr = ((s << 1) | t) & 0x3ffff
            self.noise_bit = (self.lfsr >> 16) & 1
        return self.noise_hp.process(self.noise_bit << DF)

    def sample(self):
        ext = self._noise()
        total = sum(v.sample(ext) for v in self.voices)
        if not self.audio_en:
            total = 0
        # each voice at 0.5, then x 32768 to 16 bits
        s = rnd(total, DF + 1 - 15)
        return max(-32768, min(32767, s))


def cmd_replay(a):
    import cem3394_replay as rp
    base = REPO / "debug" / f"{a.game}-snd"
    rows = rp.load_trace(base / f"{a.game}_snd.trace")
    n = int(a.secs * SR)
    out = np.zeros(n)
    if a.float:
        board = rp.Sente6VB(SR)
        noise_src, noise_hp = rp.MM5837(), rp.RCHighpass(SR, rp.NOISE_R, rp.NOISE_C)
        nstep, nph, nlev = rp.mm5837_frequency(rp.NOISE_VDD) / SR, 0.0, 0.0
    else:
        board = Board(mame_enable=a.mame_enable)
    ri = 0
    for i in range(n):
        t = i / SR
        while ri < len(rows) and rows[ri][0] <= t:
            board.write(rows[ri][1], rows[ri][2])
            ri += 1
        if a.float:
            nph += nstep
            while nph >= 1.0:
                nlev = float(noise_src.clock())
                nph -= 1.0
            out[i] = sum(v.sample(noise_hp.process(nlev)) for v in board.voices) * rp.VOICE_MIX
        else:
            out[i] = board.sample() / 32768.0
        if i % SR == 0 and i:
            print(f"  {i // SR} s", file=sys.stderr)
    ref, _ = rp.read_wav(base / f"{a.game}.wav")
    skip = int(a.skip * SR)
    m = min(len(ref), n) - skip
    r, o = ref[skip:skip + m], out[skip:skip + m]
    r_rms, o_rms = float(np.sqrt((r ** 2).mean())), float(np.sqrt((o ** 2).mean()))
    print(f"{'float model' if a.float else 'integer model'}: {m / SR:.2f} s compared from {a.skip} s")
    print(f"  level    {20 * math.log10(o_rms / r_rms):+.2f} dB against MAME")
    edges = [20, 80, 160, 320, 640, 1280, 2560, 5120, 10240, 20480]
    be_r = rp.band_energy(r / r_rms, SR, edges)
    be_o = rp.band_energy(o / o_rms, SR, edges)
    worst = max(abs(x - y) for x, y in zip(be_o, be_r) if math.isfinite(x - y))
    print(f"  octaves  worst band difference {worst:.2f} dB")
    win = SR // 10
    k = m // win
    R, O = r[:k * win].reshape(k, win), o[:k * win].reshape(k, win)
    sig = np.sqrt((R ** 2).mean(axis=1))
    err = np.sqrt(((R - O) ** 2).mean(axis=1))
    live = sig > 1e-6
    print(f"  waveform median error-to-signal {float(np.median(20 * np.log10(err[live] / sig[live]))):.1f} dB")
    ew = SR // 100
    er = np.sqrt((r[:len(r) // ew * ew].reshape(-1, ew) ** 2).mean(axis=1))
    eo = np.sqrt((o[:len(o) // ew * ew].reshape(-1, ew) ** 2).mean(axis=1))
    print(f"  envelope correlation {float(np.corrcoef(er, eo)[0, 1]):+.4f}")
    if a.save:
        np.save(a.save, out)
    return 0


def cmd_vectors(a):
    """Per sample: the port writes before it and the output, for sim/audio_tb.
    The board as the core runs it: the audio-enable bit followed from reset."""
    import cem3394_replay as rp
    rows = rp.load_trace(REPO / "debug" / f"{a.game}-snd" / f"{a.game}_snd.trace")
    n = int(a.secs * SR)
    board = Board(mame_enable=False)
    out = [f"# {a.game}, {n} samples: W port data, then S sample"]
    ri = 0
    for i in range(n):
        t = i / SR
        while ri < len(rows) and rows[ri][0] <= t:
            out.append(f"W {rows[ri][1]} {rows[ri][2]}")
            board.write(rows[ri][1], rows[ri][2])
            ri += 1
        out.append(f"S {board.sample()}")
    nl = chr(10)
    open(a.out, "w", newline=nl).write(nl.join(out) + nl)
    print(f"{n} samples -> {a.out}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("vectors")
    v.add_argument("game")
    v.add_argument("--secs", type=float, default=11.0)
    v.add_argument("--out", default="debug/cem3394/audio_vectors.txt")
    v.set_defaults(fn=cmd_vectors)
    r = sub.add_parser("replay")
    r.add_argument("game")
    r.add_argument("--secs", type=float, default=4.0)
    r.add_argument("--skip", type=float, default=0.0)
    r.add_argument("--float", action="store_true")
    r.add_argument("--save", default=None)
    r.add_argument("--hw-enable", dest="mame_enable", action="store_false",
                   help="follow the audio-enable bit as the board does (the core's "
                        "behaviour); by default MAME's is reproduced, to compare with it")
    r.set_defaults(fn=cmd_replay)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
