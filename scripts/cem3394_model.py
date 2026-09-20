#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Software model of one CEM3394 voice, ported from MAME.

    python scripts/cem3394_model.py sweep          # CV sweeps -> debug/cem3394/*.csv
    python scripts/cem3394_model.py tone --secs 1  # one note -> debug/cem3394/tone.wav

WORKFLOW section 9: the model comes before the RTL, the model is checked against
MAME, and the RTL is checked against the model. This is that model.

Ported from, and kept in the same order as, MAME at commit 5ae594ba:

    devices/sound/cem3394.cpp   the CV -> parameter mappings and the chain
    devices/sound/va_vco.cpp    polyBLEP/polyBLAMP oscillator (no sync here)
    devices/sound/va_vcf.cpp    va_lpf4, a Zavalishin TPT ladder
    devices/sound/va_vca.cpp    a multiply
    devices/sound/flt_rc.cpp    the AC-coupling high-pass

Two deliberate differences from MAME, both stated so a comparison is not read as
better than it is:

  * MAME runs the oscillator at the machine sample rate and the filter at
    max(96 kHz, that rate), resampling between them. This model runs the whole
    chain at one rate. Run MAME with `-samplerate 96000` to remove the
    resampler from the comparison.
  * MAME's `va_lpf4` adds 1e-6 of `machine().rand()` to the filter input so the
    filter can self-oscillate with no input. That is off by default here and
    seeded when on, so runs are reproducible.
"""
import argparse
import math
import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# --------------------------------------------------------------------------
# 6VB component values: sente6vb.cpp, cem3394_device::components
R_VCO = 301e3
C_VCO = 0.002e-6
C_VCF = 0.033e-6
C_AC = 10e-6
R_AC = 11e3          # internal AC coupling resistor, cem3394.cpp

# cem3394.cpp, file scope
PULSE_VOLUME = 0.25
SAWTOOTH_VOLUME = PULSE_VOLUME * 1.27
TRIANGLE_VOLUME = SAWTOOTH_VOLUME * 1.27
EXTERNAL_VOLUME = PULSE_VOLUME


def fpmod1(x):
    """MAME's fpmod1: the fractional part, in [0, 1)."""
    r = math.fmod(x, 1.0)
    return r + 1.0 if r < 0.0 else r


class VCO:
    """va_vco, configured as cem3394 does: pulse derived from the triangle,
    pulse DC compensation on, no sync. Outputs ramp, pulse and triangle."""

    def __init__(self, sample_rate):
        self.sr = float(sample_rate)
        self.phase = 0.0
        self.freq = 0.0
        self.step = 0.0
        self.pw = 0.0
        self.ramp_corr = 0.0
        self.pulse_corr = 0.0
        self.tri_corr = 0.0

    def set_freq(self, f):
        self.freq = f
        self.step = f / self.sr

    def set_pw(self, pw):
        self.pw = pw

    # --- anti-aliasing kernels -------------------------------------------
    def poly_blep(self, phase):
        s = self.step
        if phase < s:
            t = phase / s
            return t - 0.5 * t * t - 0.5
        if phase > 1.0 - s:
            t = (phase - 1.0) / s
            return t + 0.5 * t * t + 0.5
        return 0.0

    def poly_blamp(self, phase):
        s = self.step
        y = 0.0
        if 0.0 <= phase < 2.0 * s:
            x = phase / s
            u = 2.0 - x
            y -= u * u * u * u * u
            if phase < s:
                v = 1.0 - x
                y += 4.0 * v * v * v * v * v
        return y * s / 15.0

    def blep_corrections(self, disc):
        cur = nxt = 0.0
        for phase, jump in disc:
            cur += jump * self.poly_blep(phase)
            nxt += jump * self.poly_blep(fpmod1(phase + self.step))
        return cur, nxt

    def blamp_corrections(self, disc):
        cur = nxt = 0.0
        for phase, corner in disc:
            cur += corner * self.poly_blamp(1.0 - phase)
            nxt += corner * self.poly_blamp(fpmod1(phase + self.step))
        return cur, nxt

    # --- naive waveforms --------------------------------------------------
    @staticmethod
    def ramp_wave(phase):
        return 2.0 * phase - 1.0

    @staticmethod
    def tri_wave(phase):
        return 1.0 - 2.0 * abs(VCO.ramp_wave(phase))

    def pulse_wave(self, phase):
        # m_pulse_dc_comp is on for the CEM3394.
        return (1.0 if phase < self.pw else -1.0) - (self.pw + self.pw - 1.0)

    def tripulse_wave(self, phase):
        return self.pulse_wave(fpmod1(phase + 0.5 * self.pw))

    def will_wrap(self, phase):
        return phase > 1.0 - self.step

    # --- one sample -------------------------------------------------------
    def step_sample(self):
        """Returns (ramp, pulse, triangle) for the current phase, then advances."""
        p = self.phase
        reset_phase = p
        reset = self.will_wrap(reset_phase)

        # ramp: one discontinuity, at reset
        disc = [(reset_phase, -2.0)] if reset else []
        cur, nxt = self.blep_corrections(disc)
        ramp = self.ramp_wave(p) + self.ramp_corr + cur
        self.ramp_corr = nxt

        # pulse, derived from the triangle: reset (up) and flip (down)
        tp_reset = fpmod1(p + 0.5 * self.pw)
        tp_flip = fpmod1(p + 1.0 - 0.5 * self.pw)
        disc = []
        if self.will_wrap(tp_reset):
            disc.append((tp_reset, 2.0))
        if self.will_wrap(tp_flip):
            disc.append((tp_flip, -2.0))
        cur, nxt = self.blep_corrections(disc)
        pulse = self.tripulse_wave(p) + self.pulse_corr + cur
        self.pulse_corr = nxt

        # triangle: corners at the bottom (reset) and the top
        tritop = fpmod1(p + 0.5)
        disc = []
        if reset:
            disc.append((reset_phase, -1.0))
        if self.will_wrap(tritop):
            disc.append((tritop, 1.0))
        cur, nxt = self.blamp_corrections(disc)
        tri = self.tri_wave(p) + self.tri_corr + cur
        self.tri_corr = nxt

        self.phase = fpmod1(p + self.step)
        return ramp, pulse, tri


class VCOFixed:
    """va_vco in fixed point: the specification the RTL oscillator implements.

    The float `VCO` above is the port of MAME. This is what hardware can do, and
    `cem3394_model.py vco` measures the distance between them. Every value is an
    integer in a stated format, and every operation is one the RTL will perform.

      phase, step   Q0.32 unsigned. The phase accumulator IS the 32-bit counter.
      inv_step      Q12.20 unsigned, = round(2^52 / step). The polyBLEP and
                    polyBLAMP kernels divide by `step`; a reciprocal computed
                    when the frequency changes turns that into a multiply.
                    1/step runs 5.5 (17.4 kHz) to 3556 (27 Hz), hence 12 integer
                    bits.
      t, x          Q2.30 signed, the position within a discontinuity.
      waveforms     the datapath format, Q4.26 signed.

    The powers in polyBLAMP are taken as u2 = u*u, u4 = u2*u2, u5 = u4*u: three
    multiplies, not four.
    """

    PH_BITS  = 32
    INV_FRAC = 20
    T_FRAC   = 30
    P_FRAC   = 26          # the fraction used for the power chain and the output
    RECIP15  = (1 << 30) // 15 + 1     # 1/15 as Q0.30, for polyBLAMP's tail

    def __init__(self, sample_rate, data_frac=26):
        self.sr = float(sample_rate)
        self.data_frac = data_frac
        self.phase = 0
        self.step = 0
        self.inv_step = 0
        self.pw = 0                     # Q0.32
        self.ramp_corr = 0              # all corrections in the data format
        self.pulse_corr = 0
        self.tri_corr = 0

    # --- setters ---------------------------------------------------------
    def set_freq(self, f):
        self.step = int(round(f / self.sr * (1 << self.PH_BITS)))
        if self.step <= 0:
            self.step = 1
        self.inv_step = ((1 << (self.PH_BITS + self.INV_FRAC)) + self.step // 2) // self.step

    def set_pw(self, pw):
        self.pw = max(0, min((1 << self.PH_BITS) - 1,
                             int(round(pw * (1 << self.PH_BITS)))))

    # --- helpers ---------------------------------------------------------
    def _t(self, delta):
        """delta (Q0.32, signed) / step -> Q2.30. One multiply and a shift."""
        sh = self.PH_BITS + self.INV_FRAC - self.T_FRAC       # 22
        return (delta * self.inv_step + (1 << (sh - 1))) >> sh

    def _blep(self, delta):
        """poly_blep(), returning the datapath format.

        t >= 0 is the sample just after a discontinuity (phase < step), t < 0
        the sample just before it (phase > 1 - step). MAME writes the two
        branches separately; they differ only in the sign of the quadratic and
        the constant.
        """
        t = self._t(delta)
        sh = self.T_FRAC - self.P_FRAC                        # 4
        t_p = t >> sh
        t2 = (t * t) >> (2 * self.T_FRAC - self.P_FRAC)       # t^2 in Q.P_FRAC
        half = 1 << (self.P_FRAC - 1)
        if t >= 0:
            return t_p - (t2 >> 1) - half
        return t_p + (t2 >> 1) + half

    def _blamp(self, delta, near):
        """poly_blamp(). `near` is MAME's `phase < m_step` inner test."""
        x = self._t(delta)                                    # Q2.30, 0 <= x < 2
        p = self.P_FRAC
        sh = self.T_FRAC - p
        u = (2 << p) - (x >> sh)                              # 2 - x, Q.p
        u2 = (u * u) >> p
        u4 = (u2 * u2) >> p
        y = -((u4 * u) >> p)
        if near:
            v = (1 << p) - (x >> sh)
            v2 = (v * v) >> p
            v4 = (v2 * v2) >> p
            y += 4 * ((v4 * v) >> p)
        # y * step / 15
        y = (y * self.step) >> self.PH_BITS
        return (y * self.RECIP15) >> 30

    def _will_wrap(self, phase):
        return phase > ((1 << self.PH_BITS) - self.step)

    # --- one sample -------------------------------------------------------
    def step_sample(self):
        """(ramp, pulse, triangle) in the datapath format, then advance."""
        M = 1 << self.PH_BITS
        p = self.phase
        reset = self._will_wrap(p)

        def blep_pair(ph):
            """The correction for this sample and the one after it."""
            return self._blep(ph), self._blep((ph + self.step) % M - M)

        # --- ramp: one discontinuity, at the wrap
        cur = nxt = 0
        if reset:
            a, b = self._blep(p - M), self._blep((p + self.step) % M)
            cur += -2 * a
            nxt += -2 * b
        ramp = ((2 * p - M) >> (self.PH_BITS - self.P_FRAC)) + self.ramp_corr + cur
        self.ramp_corr = nxt

        # --- pulse, derived from the triangle: reset (up) and flip (down)
        tp_reset = (p + (self.pw >> 1)) % M
        tp_flip = (p + M - (self.pw >> 1)) % M
        cur = nxt = 0
        if self._will_wrap(tp_reset):
            cur += 2 * self._blep(tp_reset - M)
            nxt += 2 * self._blep((tp_reset + self.step) % M)
        if self._will_wrap(tp_flip):
            cur += -2 * self._blep(tp_flip - M)
            nxt += -2 * self._blep((tp_flip + self.step) % M)
        pulse = self._tripulse(p) + self.pulse_corr + cur
        self.pulse_corr = nxt

        # --- triangle: corners at the bottom (wrap) and the top
        tritop = (p + (M >> 1)) % M
        cur = nxt = 0
        if reset:
            cur += -self._blamp(M - p, (M - p) < self.step)
            nxt += -self._blamp((p + self.step) % M, ((p + self.step) % M) < self.step)
        if self._will_wrap(tritop):
            cur += self._blamp(M - tritop, (M - tritop) < self.step)
            nxt += self._blamp((tritop + self.step) % M, ((tritop + self.step) % M) < self.step)
        tri = self._tri(p) + self.tri_corr + cur
        self.tri_corr = nxt

        self.phase = (p + self.step) % M
        return ramp, pulse, tri

    # --- naive waveforms, in the datapath format --------------------------
    def _ramp(self, p):
        M = 1 << self.PH_BITS
        return (2 * p - M) >> (self.PH_BITS - self.P_FRAC)

    def _tri(self, p):
        r = self._ramp(p)
        return (1 << self.P_FRAC) - 2 * (r if r >= 0 else -r)

    def _pulse(self, p):
        M = 1 << self.PH_BITS
        one = 1 << self.P_FRAC
        w = one if p < self.pw else -one
        # pulse DC compensation: subtract (2*pw - 1)
        return w - ((2 * self.pw - M) >> (self.PH_BITS - self.P_FRAC))

    def _tripulse(self, p):
        M = 1 << self.PH_BITS
        return self._pulse((p + (self.pw >> 1)) % M)


class Fixed:
    """The arithmetic an RTL datapath would do: round-to-nearest, saturate.

    Only the PER-SAMPLE datapath is quantised. Coefficients are computed in
    float and then quantised once, which is what the RTL will do too: `fc` and
    `res` change at CPU-write rate, so their `tan`, reciprocal and power-of-two
    work belongs in a sequential unit or a table, not in the sample loop. The
    question this answers is whether the SAMPLE LOOP is stable in fixed point,
    not how precisely a rare coefficient update can be computed.
    """

    # Coefficients are NOT all below 1.0: `res` reaches 4.8 at the top of the
    # resonance range, `gain_comp` reaches 1 + 0.2*4.8 = 1.96, and `alpha0` is
    # exactly 1.0 when there is no resonance. Four integer bits including sign
    # covers them with room; giving them only a sign bit wraps 1.0 to -1.0.
    def __init__(self, data_int=4, data_frac=20, coef_frac=17, coef_int=4):
        self.data_frac = data_frac
        self.coef_frac = coef_frac
        self.coef_int = coef_int
        self.data_max = (1 << (data_int + data_frac - 1)) - 1
        self.data_min = -(1 << (data_int + data_frac - 1))
        self.coef_max = (1 << (coef_int + coef_frac - 1)) - 1
        self.coef_min = -(1 << (coef_int + coef_frac - 1))
        self.clipped = 0
        self.coef_clipped = 0

    def q(self, x):
        """Quantise a data value to the datapath format."""
        v = int(math.floor(x * (1 << self.data_frac) + 0.5))
        if v > self.data_max:
            v = self.data_max
            self.clipped += 1
        elif v < self.data_min:
            v = self.data_min
            self.clipped += 1
        return v / float(1 << self.data_frac)

    def qc(self, x):
        """Quantise a coefficient. A coefficient that does not fit is a design
        error, not something to silently wrap: it is reported."""
        v = int(math.floor(x * (1 << self.coef_frac) + 0.5))
        if v > self.coef_max or v < self.coef_min:
            self.coef_clipped += 1
            v = min(self.coef_max, max(self.coef_min, v))
        return v / float(1 << self.coef_frac)

    def mul(self, a, b):
        """One DSP multiply: full product, then rounded back to the datapath."""
        return self.q(a * b)


class TanhLUT:
    """tanh as an RTL does it, to the bit.

    A table of 2^LOG2N + 1 entries over [0, 4) with linear interpolation, odd
    symmetric, saturating to the last entry beyond the table. Every step is
    expressed the way the hardware will do it, so the RTL can be compared
    bit-for-bit rather than approximately:

      index    the top LOG2N bits of |x| above the x_max scale. x_max is 4 and
               the table is indexed by |x| * 2^LOG2N / 4, which for a value with
               `data_frac` fraction bits is a right shift by
               (data_frac + 2 - LOG2N) -- no multiply.
      fraction the bits below the index, used as an unsigned fraction with
               FRAC_BITS of precision.
      output   tab[i] + (tab[i+1] - tab[i]) * frac, rounded to the datapath.
    """

    LOG2N = 10
    X_MAX = 4.0

    def __init__(self, fx):
        self.fx = fx
        self.n = 1 << self.LOG2N
        # |x| >> SHIFT is the table index; the low SHIFT bits are the fraction.
        self.shift = fx.data_frac + 2 - self.LOG2N
        if self.shift < 0:
            raise ValueError("data_frac too small for this table size")
        self.frac_bits = self.shift
        self.tab = [fx.q(math.tanh(i * self.X_MAX / self.n)) for i in range(self.n + 1)]
        self.tab_i = [int(round(v * (1 << fx.data_frac))) for v in self.tab]

    def __call__(self, x):
        fx = self.fx
        neg = x < 0.0
        a = int(round((-x if neg else x) * (1 << fx.data_frac)))
        if a >= self.n << self.shift:
            y = self.tab_i[self.n]
        else:
            i = a >> self.shift
            frac = a & ((1 << self.frac_bits) - 1)
            d = self.tab_i[i + 1] - self.tab_i[i]
            # round-half-up on the interpolation product, as the RTL will
            y = self.tab_i[i] + ((d * frac + (1 << (self.frac_bits - 1))) >> self.frac_bits)
        v = -y if neg else y
        return v / float(1 << fx.data_frac)


class LPF4:
    """va_lpf4: four one-pole TPT stages with a resonance loop and a tanh
    saturator. cem3394 configures drive = 1.0 and bass gain comp = 0.2.

    With `fx` set, every per-sample operation is quantised and saturated.
    """

    W_MAX_HZ = 16000.0

    def __init__(self, sample_rate, drive=1.0, gain_comp=0.2, input_gain=1.0, fx=None):
        self.fx = fx
        self.tanh = TanhLUT(fx) if fx else math.tanh
        self.sr = float(sample_rate)
        self.drive = drive
        self.gain_comp = gain_comp
        self.input_gain = input_gain
        self.fc = 0.0
        self.res = 0.0
        self.alpha = [0.0] * 4
        self.beta = [0.0] * 4
        self.state = [0.0] * 4
        self.alpha0 = 1.0
        self.g4 = 1.0
        self.gain_comp_scale = 1.0
        self.recalc_filter()

    def set_res(self, res):
        if self.fx:
            res = self.fx.qc(res)
        if res != self.res:
            self.res = res
            self.recalc_res()

    def set_freq(self, fc):
        if fc != self.fc:
            self.fc = fc
            self.recalc_filter()

    def recalc_res(self):
        self.alpha0 = 1.0 / (1.0 + self.res * self.g4)
        self.gain_comp_scale = 1.0 + self.gain_comp * self.res
        if self.fx:
            self.alpha0 = self.fx.qc(self.alpha0)
            self.gain_comp_scale = self.fx.qc(self.gain_comp_scale)

    def recalc_filter(self):
        t = 1.0 / self.sr
        w = 2.0 * math.pi * self.fc
        w_max = 2.0 * math.pi * min(0.75 * self.sr / 2.0, self.W_MAX_HZ)
        if w <= w_max:
            g = math.tan(w * t / 2.0)
        else:
            g = math.tan(w_max * t / 2.0) / w_max * w
        gp1 = 1.0 + g
        big_g = g / gp1
        g2 = big_g * big_g
        self.g4 = g2 * g2
        self.recalc_res()
        self.alpha = [big_g] * 4
        self.beta = [g2 * big_g / gp1, g2 / gp1, big_g / gp1, 1.0 / gp1]
        if self.fx:
            self.alpha = [self.fx.qc(a) for a in self.alpha]
            self.beta = [self.fx.qc(b) for b in self.beta]

    def process(self, s, noise=0.0):
        if self.fx:
            return self._process_fixed(s, noise)
        sigma = sum(b * st for b, st in zip(self.beta, self.state))
        x = s * self.input_gain
        x += 1e-6 * noise
        x *= self.drive
        x *= self.gain_comp_scale
        u = (x - self.res * sigma) * self.alpha0
        u = math.tanh(u)
        for i in range(4):
            vn = (u - self.state[i]) * self.alpha[i]
            u = vn + self.state[i]
            self.state[i] = vn + u
        return u / self.drive

    def _process_fixed(self, s, noise):
        """Same graph, every operation rounded and saturated. drive is 1.0 for
        the CEM3394, so the input/output scaling is not modelled as multiplies."""
        fx = self.fx
        sigma = 0.0
        for b, st in zip(self.beta, self.state):
            sigma = fx.q(sigma + fx.mul(b, st))
        x = fx.q(s + 1e-6 * noise)
        x = fx.mul(x, self.gain_comp_scale)
        u = fx.mul(fx.q(x - fx.mul(self.res, sigma)), self.alpha0)
        u = self.tanh(u)
        for i in range(4):
            vn = fx.mul(fx.q(u - self.state[i]), self.alpha[i])
            u = fx.q(vn + self.state[i])
            self.state[i] = fx.q(vn + u)
        return u


class RCHighpass:
    """flt_rc HIGHPASS: y = x - mem; mem += (x - mem) * k.

    k here is tiny -- 11 kOhm and 10 uF give a 1.45 Hz corner, so k is 9.5e-5 at
    96 kHz. In fixed point the product (x - mem) * k underflows to zero for small
    errors and the DC blocker stalls short of zero. The fixed-point path keeps
    the accumulator at a wider fraction than the datapath for that reason, which
    is what the RTL will have to do too.
    """

    EXTRA_FRAC = 12

    def __init__(self, sample_rate, r, c, fx=None):
        self.mem = 0.0
        self.fx = fx
        self.k = 1.0 - math.exp(-1.0 / (r * c) / float(sample_rate))
        if fx:
            self.acc_frac = fx.data_frac + self.EXTRA_FRAC
            self.k = int(math.floor(self.k * (1 << fx.coef_frac) + 0.5)) / float(1 << fx.coef_frac)
            self.acc = 0          # integer accumulator at acc_frac bits

    def process(self, x):
        if self.fx:
            mem = self.acc / float(1 << self.acc_frac)
            y = self.fx.q(x - mem)
            step = (x - mem) * self.k
            self.acc += int(math.floor(step * (1 << self.acc_frac) + 0.5))
            return y
        y = x - self.mem
        self.mem += (x - self.mem) * self.k
        return y


def compute_db(voltage):
    """cem3394_device::compute_db. 0 V is full off, 4 V full on."""
    if voltage >= 4.0:
        return 0.0
    if voltage <= 0.0:
        return 90.0
    if voltage >= 2.5:
        return (4.0 - voltage) * (1.0 / 1.5) * 20.0
    return min(90.0, 20.0 * math.pow(2.0, 2.5 - voltage))


def compute_db_volume(voltage):
    return math.pow(0.891251, compute_db(voltage))


class CEM3394:
    """One voice: the eight control voltages and the chain they drive."""

    # Register numbers exactly as sente6vb.cpp's chip_select_w() dispatches them.
    # This is NOT the order the old driver header lists: the 6VB puts final gain
    # at 1 and wave select at 7.
    VCO_FREQ = 0
    FINAL_GAIN = 1
    FILTER_RESONANCE = 2
    FILTER_FREQUENCY = 3
    MIXER_BALANCE = 4
    MODULATION = 5
    PULSE_WIDTH = 6
    WAVE_SELECT = 7

    # sente6vb.cpp chip_select_w(): voltage = dac * (8/4096) - 4
    DAC_SCALE = 8.0 / 4096.0
    DAC_OFFSET = -4.0

    @staticmethod
    def dac_to_cv(dac_value):
        return dac_value * CEM3394.DAC_SCALE + CEM3394.DAC_OFFSET

    def __init__(self, sample_rate=96000, filter_noise=False, seed=1, fx=None):
        self.sr = float(sample_rate)
        self.fx = fx
        self.vco = VCO(sample_rate)
        self.vcf = LPF4(sample_rate, fx=fx)
        self.ac = RCHighpass(sample_rate, R_AC, C_AC, fx=fx)

        # cem3394_device's datasheet-derived constants
        self.vco_zero_freq = 1.3 / (5.0 * R_VCO * C_VCO)
        self.filter_zero_freq = 4.3e-5 / C_VCF

        self.tri = False
        self.saw = False
        self.mixer_internal = 0.0
        self.mixer_external = 0.0
        self.filter_modulation = 0.0
        self.filter_frequency = 1300.0
        self.volume = 0.0
        self.filter_noise = filter_noise
        self._rand = seed

        for reg in range(8):
            self.set_cv(reg, 0.0)

    # --- MAME's rand, only used for the filter's self-oscillation nudge ---
    def _next_noise(self):
        if not self.filter_noise:
            return 0.0
        self._rand = (1103515245 * self._rand + 12345) & 0x7fffffff
        return 2.0 * (self._rand / float(0x7fffffff) - 0.5)

    # --- CV setters, one per cem3394.cpp setter --------------------------
    def set_cv(self, reg, cv):
        if reg == self.VCO_FREQ:
            # -4..+4 V at 0.75 V/octave
            self.vco.set_freq(self.vco_zero_freq * math.pow(2.0, -cv / 0.75))
        elif reg == self.MODULATION:
            if cv < 0.01:
                self.filter_modulation = 0.0
            elif cv > 3.5:
                self.filter_modulation = 1.98
            else:
                self.filter_modulation = 1.98 * (cv - 0.01) / (3.5 - 0.01)
        elif reg == self.WAVE_SELECT:
            self.tri = (-0.5 <= cv < 1.9)
            self.saw = (cv >= 0.35)
        elif reg == self.PULSE_WIDTH:
            self.vco.set_pw(min(1.0, max(0.0, 0.5 * cv)))
        elif reg == self.MIXER_BALANCE:
            if cv >= 0.0:
                self.mixer_internal = compute_db_volume(3.55 - cv)
                self.mixer_external = compute_db_volume(3.55 + 0.45 * (cv * 0.25))
            else:
                self.mixer_internal = compute_db_volume(3.55 - 0.45 * (cv * 0.25))
                self.mixer_external = compute_db_volume(3.55 + cv)
        elif reg == self.FILTER_RESONANCE:
            self.vcf.set_res(0.0 if cv < 0.0 else 4.0 * cv / 2.5)
        elif reg == self.FILTER_FREQUENCY:
            # -3..+4 V at 0.375 V/octave
            self.filter_frequency = self.filter_zero_freq * math.pow(2.0, -cv / 0.375)
        elif reg == self.FINAL_GAIN:
            self.volume = compute_db_volume(cv)
        else:
            raise ValueError(f"register {reg} does not exist")

    # --- reported values, as the 6VB's calibration code would measure -----
    @property
    def vco_freq(self):
        return self.vco.freq

    @property
    def filt_freq(self):
        return self.filter_frequency

    @property
    def filt_res(self):
        return self.vcf.res

    @property
    def final_gain(self):
        return self.volume

    def sample(self, ext_input=0.0):
        ramp, pulse, tri = self.vco.step_sample()

        saw_gain = SAWTOOTH_VOLUME * self.mixer_internal if self.saw else 0.0
        tri_gain = TRIANGLE_VOLUME * self.mixer_internal if self.tri else 0.0
        pulse_gain = PULSE_VOLUME * self.mixer_internal
        ext_gain = EXTERNAL_VOLUME * self.mixer_external

        audio = ramp * saw_gain + pulse * pulse_gain + tri * tri_gain + ext_input * ext_gain

        # The filter's cutoff is FM'd by the triangle: filt_fm's VCA output is
        # filt_freq * mod_amount * 0.5 * triangle, summed into INPUT_FREQ.
        fc = self.filter_frequency * (1.0 + 0.5 * self.filter_modulation * tri)
        self.vcf.set_freq(fc)

        if self.fx:
            audio = self.fx.q(audio)
        y = self.vcf.process(audio, self._next_noise())
        y = self.ac.process(y)
        return self.fx.mul(y, self.volume) if self.fx else y * self.volume


# --------------------------------------------------------------------------
def out_dir():
    d = REPO / "debug" / "cem3394"
    d.mkdir(parents=True, exist_ok=True)
    return d


def write_wav(path, samples, sample_rate):
    peak = max((abs(s) for s in samples), default=0.0) or 1.0
    scale = 32767.0 / max(1.0, peak)
    pcm = b"".join(struct.pack("<h", int(max(-32768, min(32767, s * scale)))) for s in samples)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16))
        f.write(b"data" + struct.pack("<I", len(pcm)) + pcm)
    return peak


def cmd_tone(a):
    v = CEM3394(a.rate)
    v.set_cv(CEM3394.VCO_FREQ, a.vco_cv)
    v.set_cv(CEM3394.WAVE_SELECT, a.wave_cv)
    v.set_cv(CEM3394.PULSE_WIDTH, a.pw_cv)
    v.set_cv(CEM3394.MIXER_BALANCE, -4.0)          # fully internal
    v.set_cv(CEM3394.FILTER_FREQUENCY, a.filt_cv)
    v.set_cv(CEM3394.FILTER_RESONANCE, a.res_cv)
    v.set_cv(CEM3394.FINAL_GAIN, 4.0)              # 0 dB
    n = int(a.secs * a.rate)
    s = [v.sample() for _ in range(n)]
    p = out_dir() / "tone.wav"
    peak = write_wav(p, s, a.rate)
    print(f"VCO {v.vco_freq:.2f} Hz, filter {v.filt_freq:.1f} Hz, res {v.filt_res:.3f}, "
          f"gain {v.final_gain:.4f}")
    print(f"{n} samples, peak {peak:.4f} -> {p}")
    return 0


def measure_freq(v, rate, secs=0.25):
    """Zero crossings of the voice output, as the 8253 counter would see them."""
    n = int(secs * rate)
    prev = v.sample()
    crossings, first, last = 0, None, None
    for i in range(1, n):
        s = v.sample()
        if prev < 0.0 <= s:
            crossings += 1
            if first is None:
                first = i
            last = i
        prev = s
    if crossings < 2 or first is None or last == first:
        return 0.0
    return (crossings - 1) * rate / float(last - first)


def cmd_sweep(a):
    """Every CV across its datasheet range, against the documented transfer
    functions. This is the table the RTL has to reproduce."""
    d = out_dir()

    p = d / "vco_freq.csv"
    with open(p, "w", encoding="ascii") as f:
        f.write("cv,model_hz,datasheet_hz,rel_err\n")
        cv = -4.0
        while cv <= 4.0001:
            v = CEM3394(a.rate)
            v.set_cv(CEM3394.VCO_FREQ, cv)
            want = 431.894 * math.pow(2.0, -cv / 0.75)
            got = v.vco_freq
            f.write(f"{cv:.3f},{got:.6f},{want:.6f},{(got - want) / want:.3e}\n")
            cv += 0.25
    print(f"VCO frequency law -> {p}")

    p = d / "filter_freq.csv"
    with open(p, "w", encoding="ascii") as f:
        f.write("cv,model_hz\n")
        cv = -3.0
        while cv <= 4.0001:
            v = CEM3394(a.rate)
            v.set_cv(CEM3394.FILTER_FREQUENCY, cv)
            f.write(f"{cv:.3f},{v.filt_freq:.6f}\n")
            cv += 0.25
    print(f"filter frequency law -> {p}")

    p = d / "gain.csv"
    with open(p, "w", encoding="ascii") as f:
        f.write("cv,db,volume\n")
        cv = 0.0
        while cv <= 4.0001:
            f.write(f"{cv:.3f},{compute_db(cv):.6f},{compute_db_volume(cv):.8f}\n")
            cv += 0.125
    print(f"final gain law -> {p}")

    # Pitch accuracy through the whole chain: this is what decides whether the
    # 6VB's calibration routine converges.
    p = d / "pitch_tracking.csv"
    worst = 0.0
    with open(p, "w", encoding="ascii") as f:
        f.write("vco_cv,nominal_hz,measured_hz,rel_err\n")
        cv = -2.0
        while cv <= 3.0001:
            v = CEM3394(a.rate)
            v.set_cv(CEM3394.VCO_FREQ, cv)
            v.set_cv(CEM3394.WAVE_SELECT, 3.0)      # sawtooth
            v.set_cv(CEM3394.MIXER_BALANCE, -4.0)
            v.set_cv(CEM3394.FILTER_FREQUENCY, -3.0)  # wide open
            v.set_cv(CEM3394.FILTER_RESONANCE, 0.0)
            v.set_cv(CEM3394.FINAL_GAIN, 4.0)
            nominal = v.vco_freq
            got = measure_freq(v, a.rate)
            err = (got - nominal) / nominal if nominal else 0.0
            worst = max(worst, abs(err))
            f.write(f"{cv:.3f},{nominal:.4f},{got:.4f},{err:.3e}\n")
            cv += 0.5
    print(f"pitch through the chain -> {p}   worst relative error {worst:.3e}")

    # Stability at high resonance: the filter must not blow up or go silent.
    p = d / "resonance.csv"
    with open(p, "w", encoding="ascii") as f:
        f.write("res_cv,resonance,peak,rms,stable\n")
        cv = 0.0
        while cv <= 3.0001:
            v = CEM3394(a.rate, filter_noise=True)
            v.set_cv(CEM3394.VCO_FREQ, 0.0)
            v.set_cv(CEM3394.WAVE_SELECT, 3.0)
            v.set_cv(CEM3394.MIXER_BALANCE, -4.0)
            v.set_cv(CEM3394.FILTER_FREQUENCY, 0.0)
            v.set_cv(CEM3394.FILTER_RESONANCE, cv)
            v.set_cv(CEM3394.FINAL_GAIN, 4.0)
            n = int(0.25 * a.rate)
            peak = 0.0
            acc = 0.0
            ok = True
            for _ in range(n):
                s = v.sample()
                if not math.isfinite(s):
                    ok = False
                    break
                peak = max(peak, abs(s))
                acc += s * s
            rms = math.sqrt(acc / n) if ok else float("nan")
            f.write(f"{cv:.3f},{v.filt_res:.4f},{peak:.6f},{rms:.6f},{int(ok)}\n")
            cv += 0.25
    print(f"resonance stability -> {p}")
    return 0


def _voice(rate, fx, vco_cv, wave_cv, filt_cv, res_cv, noise=False):
    v = CEM3394(rate, filter_noise=noise, fx=fx)
    v.set_cv(CEM3394.VCO_FREQ, vco_cv)
    v.set_cv(CEM3394.WAVE_SELECT, wave_cv)
    v.set_cv(CEM3394.PULSE_WIDTH, 1.0)
    v.set_cv(CEM3394.MIXER_BALANCE, -4.0)
    v.set_cv(CEM3394.FILTER_FREQUENCY, filt_cv)
    v.set_cv(CEM3394.FILTER_RESONANCE, res_cv)
    v.set_cv(CEM3394.FINAL_GAIN, 4.0)
    return v


def fixed_error_scan(rate, secs, fx_args, points=None):
    """Float vs quantised over a grid. Returns (rows, unstable).

    Two error figures, because they answer different questions:
      err_db      error relative to the signal at that setting. Misleading where
                  the filter is nearly closed and the signal is tiny.
      err_dbfs    error relative to full scale. This is the audible noise floor.
    """
    points = points or [(v, f, r)
                        for v in (-1.0, 0.0, 1.0, 2.0)
                        for f in (-2.0, 0.0, 2.0)
                        for r in (0.0, 1.0, 2.0, 2.5, 3.0)]
    n = int(secs * rate)
    rows, unstable = [], []
    for vco_cv, filt_cv, res_cv in points:
        fx = Fixed(**fx_args)
        fv = _voice(rate, None, vco_cv, 3.0, filt_cv, res_cv)
        qv = _voice(rate, fx, vco_cv, 3.0, filt_cv, res_cv)
        facc = qacc = eacc = 0.0
        peak = 0.0
        ok = True
        for _ in range(n):
            fs = fv.sample()
            qs = qv.sample()
            if not (math.isfinite(fs) and math.isfinite(qs)):
                ok = False
                break
            facc += fs * fs
            qacc += qs * qs
            eacc += (fs - qs) * (fs - qs)
            peak = max(peak, abs(qs))
        if not ok:
            unstable.append((vco_cv, filt_cv, res_cv))
            continue
        frms = math.sqrt(facc / n)
        qrms = math.sqrt(qacc / n)
        erms = math.sqrt(eacc / n)
        db = 20.0 * math.log10(erms / frms) if frms > 0 and erms > 0 else -999.0
        dbfs = 20.0 * math.log10(erms) if erms > 0 else -999.0
        rows.append((vco_cv, filt_cv, res_cv, qv.filt_res, frms, qrms, erms,
                     db, dbfs, peak, fx.clipped))
    return rows, unstable


# Resonance at or above this makes the filter an oscillator rather than a
# filter (cem3394.cpp maps 2.5 V to a resonance gain of 4, "oscillation starts
# between 2.0 and 3.0 V"). Past it, the float and fixed models are two copies of
# the same chaotic oscillator: they drift apart in phase however many bits are
# used, so a sample-by-sample error is not a measure of precision. Those points
# are judged on staying bounded and on matching level instead.
OSC_RES = 4.0


def cmd_vco(a):
    """The fixed-point oscillator against the float one, per waveform.

    The float VCO is the port of MAME; VCOFixed is what the RTL will implement.
    This says what the quantisation costs, before any RTL exists to blame.
    """
    scale = float(1 << VCOFixed.P_FRAC)
    print(f"{a.rate} Hz, {a.secs}s per frequency, Q{a.data_int}.{VCOFixed.P_FRAC} output")
    print(f"{'VCO cv':>7} {'freq Hz':>10} {'wave':>9} {'err rms':>10} {'err/FS dB':>10} "
          f"{'max err':>9}")
    worst = -999.0
    n = int(a.secs * a.rate)
    for cv in (-3.0, -1.5, 0.0, 1.5, 3.0):
        f = 431.894 * math.pow(2.0, -cv / 0.75)
        fx = VCOFixed(a.rate, a.data_frac)
        fx.set_freq(f)
        fx.set_pw(0.5)
        fl = VCO(a.rate)
        fl.set_freq(f)
        fl.set_pw(0.5)
        # Give the float VCO the SAME frequency the 32-bit accumulator can
        # actually produce. Otherwise the two drift apart in phase and the
        # comparison measures frequency resolution, not the kernels -- which is
        # what the first version of this did: it made low notes look ten times
        # worse than high ones, because a longer period accumulates more drift.
        # Frequency resolution is reported separately below; it is irreducible
        # and inaudible.
        fl.step = fx.step / float(1 << VCOFixed.PH_BITS)
        fl.pw = (fx.pw >> 1) * 2 / float(1 << VCOFixed.PH_BITS)
        acc = [0.0, 0.0, 0.0]
        mx = [0.0, 0.0, 0.0]
        for _ in range(n):
            a3 = fl.step_sample()
            b3 = fx.step_sample()
            for k in range(3):
                e = a3[k] - b3[k] / scale
                acc[k] += e * e
                mx[k] = max(mx[k], abs(e))
        for k, name in enumerate(("ramp", "pulse", "triangle")):
            rms = math.sqrt(acc[k] / n)
            db = 20.0 * math.log10(rms) if rms > 0 else -999.0
            worst = max(worst, db)
            print(f"{cv:>7.1f} {f:>10.2f} {name:>9} {rms:>10.2e} {db:>10.1f} {mx[k]:>9.2e}")
    print(f"\nkernel quantisation, worst relative to full scale: {worst:.1f} dBFS")
    print("A 16-bit output's own floor is -96 dBFS.")

    # The other half: what a 32-bit phase accumulator can express at all.
    print("\nfrequency resolution of the Q0.32 accumulator:")
    print(f"  {'VCO cv':>7} {'wanted Hz':>12} {'nearest Hz':>12} {'error':>10} {'cents':>8}")
    worst_c = 0.0
    for cv in (-4.0, -2.0, 0.0, 2.0, 3.0):
        f = 431.894 * math.pow(2.0, -cv / 0.75)
        fx = VCOFixed(a.rate, a.data_frac)
        fx.set_freq(f)
        got = fx.step / float(1 << VCOFixed.PH_BITS) * a.rate
        cents = 1200.0 * math.log2(got / f) if got > 0 else 0.0
        worst_c = max(worst_c, abs(cents))
        print(f"  {cv:>7.1f} {f:>12.4f} {got:>12.4f} {(got - f) / f:>10.1e} {cents:>8.5f}")
    print(f"  worst {worst_c:.5f} cents -- a semitone is 100, and the 6VB tunes "
          f"by ear against its own oscillators")
    return 0


def cmd_vectors(a):
    """Bit-exact stimulus and expected output for the RTL ladder filter.

    The filter is the part of the chain with a feedback loop, so it is the part
    where fixed point can misbehave and the part the RTL is checked against
    first. Everything is written as INTEGERS in the datapath's own format: the
    RTL has to reproduce them exactly, not approximately.

    debug/cem3394/lpf4_vectors.txt
      header   data_int data_frac coef_frac tanh_log2n tanh_shift
      coeffs   one line per operating point: alpha beta0..3 alpha0 res gcomp
      samples  in out, one line each, grouped under their coefficient line
    """
    fx = Fixed(data_int=a.data_int, data_frac=a.data_frac, coef_frac=a.coef_frac,
               coef_int=a.coef_int)
    tl = TanhLUT(fx)
    d = out_dir()
    p = d / "lpf4_vectors.txt"
    qd = lambda v: int(round(v * (1 << fx.data_frac)))     # noqa: E731
    qc = lambda v: int(round(v * (1 << fx.coef_frac)))     # noqa: E731

    points = [(fc, res_cv) for fc in (200.0, 1300.0, 8000.0, 30000.0)
              for res_cv in (0.0, 1.0, 2.0, 2.5, 3.0)]
    n = int(a.secs * a.rate)
    total = 0
    with open(p, "w", encoding="ascii") as f:
        print(f"# format {a.data_int} {a.data_frac} {a.coef_int} {a.coef_frac} "
              f"{TanhLUT.LOG2N} {tl.shift}", file=f)
        print(f"# rate {a.rate} points {len(points)} samples_per_point {n}", file=f)
        for fc, res_cv in points:
            flt = LPF4(a.rate, fx=fx)
            flt.set_freq(fc)
            flt.set_res(0.0 if res_cv < 0 else 4.0 * res_cv / 2.5)
            print(f"C {qc(flt.alpha[0])} {qc(flt.beta[0])} {qc(flt.beta[1])} "
                  f"{qc(flt.beta[2])} {qc(flt.beta[3])} {qc(flt.alpha0)} "
                  f"{qc(flt.res)} {qc(flt.gain_comp_scale)} {n}", file=f)
            # A sawtooth at 431.894 Hz (the chip's zero-CV pitch) scaled to the
            # mixer gain a real voice would apply: enough level to exercise the
            # saturator without pinning it.
            step = 431.894 / a.rate
            ph = 0.0
            for _ in range(n):
                s = fx.q((2.0 * ph - 1.0) * 0.4)
                ph = fpmod1(ph + step)
                y = flt.process(s, 0.0)
                print(f"S {qd(s)} {qd(y)}", file=f)
                total += 1
    # The tanh table, as the RTL reads it. Written here so there is exactly one
    # definition of it and the two sides cannot drift apart.
    tp = d / "tanh_table.hex"
    width = (a.data_int + a.data_frac + 3) // 4
    with open(tp, "w", encoding="ascii") as f:
        for v in tl.tab_i:
            print(f"{v & ((1 << (a.data_int + a.data_frac)) - 1):0{width}x}", file=f)
    print(f"{len(tl.tab_i)} tanh entries -> {tp}")

    # --- oscillator vectors, the same idea for the VCO -------------------
    vp = d / "vco_vectors.txt"
    vtotal = 0
    with open(vp, "w", encoding="ascii") as f:
        print(f"# format {VCOFixed.PH_BITS} {VCOFixed.INV_FRAC} {VCOFixed.T_FRAC} "
              f"{VCOFixed.P_FRAC}", file=f)
        print(f"# rate {a.rate}", file=f)
        # Frequencies chosen to land the discontinuities differently against the
        # sample grid: near-Nyquist, an exact divisor, and awkward ratios.
        for cv, pw in ((-3.0, 0.5), (-1.5, 0.5), (0.0, 0.5), (0.0, 0.1),
                       (1.5, 0.9), (3.0, 0.5)):
            fq = 431.894 * math.pow(2.0, -cv / 0.75)
            osc = VCOFixed(a.rate, a.data_frac)
            osc.set_freq(fq)
            osc.set_pw(pw)
            vn = int(a.secs * a.rate)
            print(f"V {osc.step} {osc.inv_step} {osc.pw} {vn}", file=f)
            for _ in range(vn):
                ph = osc.phase
                r, pu, tr = osc.step_sample()
                print(f"S {ph} {r} {pu} {tr}", file=f)
                vtotal += 1
    print(f"6 oscillator settings x {int(a.secs * a.rate)} samples = {vtotal} "
          f"vectors -> {vp}")

    print(f"{len(points)} operating points x {n} samples = {total} vectors -> {p}")
    if fx.coef_clipped:
        print(f"WARNING {fx.coef_clipped} coefficients did not fit Q{a.coef_int}.{a.coef_frac}")
    print(f"format Q{a.data_int}.{a.data_frac}, Q{a.coef_int}.{a.coef_frac} coefficients, "
          f"tanh {1 << TanhLUT.LOG2N}-entry table, {tl.shift}-bit interpolation fraction")
    return 0


def cmd_widths(a):
    """What word width the RTL datapath needs. The float model is the reference."""
    formats = [(4, 18, 17), (4, 20, 17), (4, 22, 18), (4, 24, 18),
               (4, 26, 22), (4, 28, 24), (4, 30, 26)]
    print(f"{a.rate} Hz, {a.secs}s per point, 60 operating points per format")
    print(f"filtering regime (resonance < {OSC_RES}) judged on sample error; "
          f"self-oscillating regime on boundedness and level\n")
    print(f"{'format':>14} {'worst err/sig':>14} {'worst err/FS':>13} "
          f"{'osc level err':>14} {'clip':>5} {'unstable':>9}")
    best = None
    for di, df, cf in formats:
        rows, unstable = fixed_error_scan(a.rate, a.secs,
                                          dict(data_int=di, data_frac=df, coef_frac=cf))
        if not rows:
            print(f"{f'Q{di}.{df}/c{cf}':>14} {'-':>14} {'-':>13} {'-':>14} "
                  f"{'-':>5} {len(unstable):>9}")
            continue
        filt = [r for r in rows if r[3] < OSC_RES]
        osc = [r for r in rows if r[3] >= OSC_RES]
        w_sig = max(r[7] for r in filt) if filt else -999.0
        w_fs = max(r[8] for r in filt) if filt else -999.0
        # For the oscillating points: how far the fixed model's RMS is from the
        # float model's, in dB. Phase is expected to differ; level is not.
        lvl = 0.0
        for r in osc:
            if r[4] > 0 and r[5] > 0:
                lvl = max(lvl, abs(20.0 * math.log10(r[5] / r[4])))
        clip = sum(r[10] for r in rows)
        print(f"{f'Q{di}.{df}/c{cf}':>14} {w_sig:>13.1f}dB {w_fs:>12.1f}dB "
              f"{lvl:>13.2f}dB {clip:>5} {len(unstable):>9}")
        if best is None and w_fs <= a.target_dbfs and not unstable:
            best = (di, df, cf, w_sig, w_fs, lvl)
    if best:
        di, df, cf, w_sig, w_fs, lvl = best
        print(f"\nnarrowest format meeting {a.target_dbfs:.0f} dBFS in the filtering "
              f"regime: Q{di}.{df} data, {cf}-bit coefficients ({di + df} bit "
              f"datapath)\n  worst noise floor {w_fs:.1f} dBFS, worst "
              f"error-to-signal {w_sig:.1f} dB, self-oscillation level within "
              f"{lvl:.2f} dB")
    else:
        print(f"\nno tested format reached {a.target_dbfs:.0f} dBFS")
    return 0


def cmd_fixed(a):
    """One format, every operating point, written out for inspection."""
    fx_args = dict(data_int=a.data_int, data_frac=a.data_frac, coef_frac=a.coef_frac)
    rows, unstable = fixed_error_scan(a.rate, a.secs, fx_args)
    p = out_dir() / "fixed_vs_float.csv"
    with open(p, "w", encoding="ascii") as f:
        cols = ("vco_cv,filt_cv,res_cv,resonance,float_rms,fixed_rms,err_rms,"
                "err_db,err_dbfs,fixed_peak,clipped")
        print(cols, file=f)
        for r in rows:
            print("%g,%g,%g,%.3f,%.6f,%.6f,%.3e,%.2f,%.2f,%.6f,%d" % r, file=f)
    print(f"Q{a.data_int}.{a.data_frac} data, {a.coef_frac}-bit coefficients, "
          f"{a.rate} Hz, {a.secs}s per point")
    print(f"{len(rows)} operating points -> {p}")
    if unstable:
        print(f"UNSTABLE at {len(unstable)} points: {unstable[:5]}")
        return 1
    filt = [r for r in rows if r[3] < OSC_RES]
    print(f"all {len(rows)} points finite and bounded; in the filtering regime "
          f"worst noise floor {max(r[8] for r in filt):.1f} dBFS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["tone", "sweep", "fixed", "widths", "vectors", "vco"])
    ap.add_argument("--data-int", type=int, default=4, help="integer bits, signed")
    ap.add_argument("--data-frac", type=int, default=20)
    ap.add_argument("--coef-frac", type=int, default=17)
    ap.add_argument("--coef-int", type=int, default=4,
                    help="coefficient integer bits including sign; res reaches 4.8")
    ap.add_argument("--target-dbfs", type=float, default=-90.0,
                    help="noise floor the datapath must reach, relative to full scale")
    ap.add_argument("--rate", type=int, default=96000,
                    help="sample rate; MAME's filter runs at max(96000, -samplerate)")
    ap.add_argument("--secs", type=float, default=1.0)
    ap.add_argument("--vco-cv", type=float, default=0.0)
    ap.add_argument("--wave-cv", type=float, default=3.0, help="3.0 = sawtooth")
    ap.add_argument("--pw-cv", type=float, default=1.0, help="1.0 = half duty cycle")
    ap.add_argument("--filt-cv", type=float, default=0.0)
    ap.add_argument("--res-cv", type=float, default=0.0)
    a = ap.parse_args()
    return {"tone": cmd_tone, "sweep": cmd_sweep, "fixed": cmd_fixed,
            "widths": cmd_widths,
            "vectors": cmd_vectors,
            "vco": cmd_vco}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
