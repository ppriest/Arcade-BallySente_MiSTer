#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The CEM3394 filter's coefficient unit, in integers: the specification the RTL
builds, and a sweep of its error against the floating-point formulas.

    python scripts/cem3394_coef.py check        # worst error over the whole range
    python scripts/cem3394_coef.py tables       # write the tables' .hex files

WHY A UNIT AND NOT A TABLE. The cutoff is frequency-modulated by the voice's
own triangle every sample (cem3394.cpp routes filt_freq * mod * 0.5 * tri into
va_lpf4's INPUT_FREQ), so under modulation every coefficient changes every
sample. va_lpf4 recomputes them with tan() and two divisions; this does the
same with tables, shifts and 27x27 multiplies:

    a      = fc / sample_rate, as a mantissa (Q1.25, [1,2)) and an exponent.
             The unmodulated part comes from the DAC code through a 384-entry
             exp table (the same split as rtl/sound/sente6vb_steptab.sv); the
             per-sample factor 1 + (mod/2)*tri multiplies the mantissa.
    g      = tan(pi*a) = a * P(a), P(a) = tan(pi*a)/a from an interpolated
             table below 1/6. At and above 1/6 P is 6*tan(pi/6): va_lpf4 clamps
             w at 16 kHz and continues linearly, which is the same thing.
    r      = 1 / (1 + g): normalise, table, interpolate, one Newton step.
    G      = g * r;  beta = (G^3 r, G^2 r, G r, r);  g4 = G^4
    alpha0 = 1 / (1 + res * g4), by the same reciprocal.

Every number is an integer in a stated format; `float_coeffs` is va_lpf4's
recalc_filter()/recalc_res() for the comparison. Output coefficients are the
filter RTL's Q4.22 (rtl/sound/cem3394_lpf4.sv).
"""
import argparse
import math
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SR = 96000.0
C_VCF = 0.033e-6
Z_F = 4.3e-5 / C_VCF                 # cem3394 m_filter_zero_freq
W_MAX_HZ = 16000.0                   # va_lpf4: min(0.75*sr/2, 16 kHz) at 96 kHz
CF = 22                              # output coefficient fraction (Q4.22)

MF = 25                              # mantissa fraction: [1,2) as Q1.25
F26 = 26                             # internal fixed fraction

P_LOG2N = 8                          # P(a) table over a in [0, 1/4)
R_LOG2N = 8                          # 1/m table over m in [1, 2)


def rnd(x, sh):
    """Round-half-up right shift, the RTL's rounding everywhere."""
    return (x + (1 << (sh - 1))) >> sh if sh > 0 else x << (-sh)


# --------------------------------------------------------------- the tables
def base_table():
    """a_base = B * 2^(-x/384), x = 2*dac. Entry r: mantissa of B*2^(-r/384) as
    Q1.25 and its exponent, so a_base = mant * 2^(exp - q) with q = x div 384."""
    b = Z_F * 2.0 ** (4.0 / 0.375) / SR
    out = []
    for r in range(384):
        v = b * 2.0 ** (-r / 384.0)
        e = math.floor(math.log2(v))
        out.append((round(v / 2.0 ** e * (1 << MF)), e))
    return out


def p_table():
    """P(a) = tan(pi a)/a over a in [0, 1/4], Q2.24, 2^P_LOG2N + 1 entries.
    The formula carries on past 1/6, where the unit uses PK instead: an entry
    clamped to PK there would bend the interpolation in the segment that
    contains 1/6."""
    n = 1 << P_LOG2N
    return [round((math.pi if i == 0 else math.tan(math.pi * i / (4.0 * n)) * 4.0 * n / i)
                  * (1 << 24)) for i in range(n + 1)]


PK_F = 6.0 * math.tan(math.pi / 6.0)       # P at and above a = 1/6
PK = round(PK_F * (1 << 24))
A_SIXTH = None                             # 1/6 as the unit's fixed-point a, set below


def r_table():
    """1/m over m in [1, 2), Q1.26, 2^R_LOG2N + 1 entries (the last is 1/2)."""
    n = 1 << R_LOG2N
    return [round((1 << F26) / (1.0 + i / n)) for i in range(n + 1)]


BASE = base_table()
PTAB = p_table()
RTAB = r_table()


# ------------------------------------------------------------ the arithmetic
def norm(v, frac):
    """v (an unsigned integer with `frac` fraction bits) -> (Q1.25 mantissa, exponent)."""
    if v <= 0:
        return 0, -200
    top = v.bit_length() - 1                 # the leading one's position
    e = top - frac
    sh = top - MF
    m = rnd(v, sh) if sh > 0 else v << (-sh)
    if m >= (2 << MF):                       # rounding carried into the next bit
        m >>= 1
        e += 1
    return m, e


def to_fixed(m, e, frac):
    """(Q1.25 mantissa, exponent) -> unsigned fixed with `frac` fraction bits."""
    sh = MF - e - frac
    return rnd(m, sh) if sh > 0 else m << (-sh)


def recip(m):
    """1/m for a Q1.25 mantissa m in [1,2): Q1.26 in (1/2, 1].
    Table with linear interpolation, then one Newton step r(2 - m r)."""
    idx = (m - (1 << MF)) >> (MF - R_LOG2N)
    fr = (m - (1 << MF)) & ((1 << (MF - R_LOG2N)) - 1)
    d = RTAB[idx + 1] - RTAB[idx]
    r0 = RTAB[idx] + rnd(d * fr, MF - R_LOG2N)
    # Newton: m is Q1.25, r0 Q1.26 -> m*r0 is Q2.51; bring to Q2.26
    mr = rnd(m * r0, MF)
    two_minus = (2 << F26) - mr
    return rnd(r0 * two_minus, F26)


def base_of_dac(dac):
    """The unmodulated cutoff argument for a filter-frequency DAC code."""
    x = 2 * dac
    q, r = divmod(x, 384)                    # the RTL does this with comparators
    m, e = BASE[r]
    return m, e - q


def res_of_dac(dac):
    """res = 4*cv/2.5 for cv >= 0, cv = dac/512 - 4: (dac - 2048)/320, Q4.22."""
    if dac <= 2048:
        return 0
    return rnd((dac - 2048) * round((1 << (CF + 16)) / 320.0), 16)


def gcomp_of_res(res):
    """1 + 0.2*res, Q4.22."""
    return (1 << CF) + rnd(res * round(0.2 * (1 << 20)), 20)


def coeffs(a_m, a_e, res):
    """The six filter coefficients for one sample, Q4.22 integers:
    alpha(=G), beta0..3, alpha0."""
    # --- g = a * P(a)
    a_fix = to_fixed(a_m, a_e, 32)           # a as Q0.32 when a < 1
    if a_e >= -2 or a_fix >= A_SIXTH:        # a >= 1/4, or 1/6 <= a < 1/4
        p = PK
    else:
        n = P_LOG2N
        idx = a_fix >> (30 - n)              # a < 1/4: index over [0, 1/4)
        fr = a_fix & ((1 << (30 - n)) - 1)
        d = PTAB[idx + 1] - PTAB[idx]
        p = PTAB[idx] + rnd(d * fr, 30 - n)
    g_m, g_e = norm(a_m * p, MF + 24)        # Q1.25 x Q2.24
    g_e += a_e
    # --- r = 1/(1 + g)
    y = (1 << 40) + to_fixed(g_m, g_e, 40)   # Q7.40, never zero
    y_m, y_e = norm(y, 40)
    rm = recip(y_m)                          # Q1.26 of 1/y_m
    r = rnd(rm, y_e) if y_e > 0 else rm      # 1/y = (1/y_m) * 2^-y_e
    # --- G = g * r, in Q1.26, from the UNSHIFTED reciprocal: r's own rounding,
    # multiplied by g (up to ~130), would otherwise cost several output LSBs.
    # g (Q1.25 * 2^g_e) * rm (Q1.26 * 2^-y_e) -> Q1.26: right by 25 - g_e + y_e
    sh = MF - g_e + y_e
    big_g = rnd(g_m * rm, sh) if sh > 0 else (g_m * rm) << (-sh)
    g2 = rnd(big_g * big_g, F26)
    beta3 = r
    beta2 = rnd(big_g * r, F26)
    beta1 = rnd(g2 * r, F26)
    beta0 = rnd(g2 * beta2, F26)
    g4 = rnd(g2 * g2, F26)
    # --- alpha0 = 1/(1 + res*g4); res Q4.22, g4 Q1.26
    den = (1 << F26) + rnd(res * g4, CF)     # Q?.26, in [1, 5.8]
    d_m, d_e = norm(den, F26)
    a0 = recip(d_m)
    a0 = rnd(a0, d_e) if d_e > 0 else a0
    sh = F26 - CF
    return [rnd(v, sh) for v in (big_g, beta0, beta1, beta2, beta3, a0)]


A_SIXTH = round((1 << 32) / 6.0)


def mod_of_dac(dac):
    """filter_modulation / 2 as Q0.26: cem3394 set_mod_amount_cv, halved."""
    cv = dac * (8.0 / 4096.0) - 4.0
    if cv < 0.01:
        v = 0.0
    elif cv > 3.5:
        v = 1.98
    else:
        v = 1.98 * (cv - 0.01) / (3.5 - 0.01)
    return round(v * 0.5 * (1 << F26))


def modulate(base_m, base_e, mod_half, tri):
    """a = base * (1 + (mod/2)*tri); tri is the voice's triangle in Q4.26."""
    f = (1 << F26) + rnd(mod_half * tri, F26)
    f = max(f, 1 << (F26 - 12))              # MAME's fc stays positive; so does this
    m, e = norm(base_m * f, MF + F26)
    return m, e + base_e


# ------------------------------------------------------------- the reference
def float_coeffs(fc, res):
    """va_lpf4 recalc_filter() + recalc_res(), in float."""
    t = 1.0 / SR
    w = 2.0 * math.pi * fc
    w_max = 2.0 * math.pi * min(0.75 * SR / 2.0, W_MAX_HZ)
    g = math.tan(w * t / 2.0) if w <= w_max else math.tan(w_max * t / 2.0) / w_max * w
    gp1 = 1.0 + g
    big_g = g / gp1
    g2 = big_g * big_g
    g4 = g2 * g2
    alpha0 = 1.0 / (1.0 + res * g4)
    return [big_g, g2 * big_g / gp1, g2 / gp1, big_g / gp1, 1.0 / gp1, alpha0]


def cmd_check(a):
    names = ["alpha", "beta0", "beta1", "beta2", "beta3", "alpha0"]
    worst = [(0.0, None)] * 6
    n = 0
    for dac in range(0, 4096, a.stride):
        bm, be = base_of_dac(dac)
        for res_dac in (2048, 2500, 3000, 3328, 3500, 4095):
            res = res_of_dac(res_dac)
            for mod_dac in (2048, 3000, 4095):
                mh = mod_of_dac(mod_dac)
                for tri in (-(1 << F26), -(1 << 25), 0, 1 << 25, 1 << F26):
                    am, ae = modulate(bm, be, mh, tri)
                    got = coeffs(am, ae, res)
                    a_val = am / float(1 << MF) * 2.0 ** ae
                    want = float_coeffs(a_val * SR, res / float(1 << CF))
                    n += 1
                    for i in range(6):
                        err = abs(got[i] - want[i] * (1 << CF))
                        if err > worst[i][0]:
                            worst[i] = (err, (dac, res_dac, mod_dac, tri, a_val * SR))
    print(f"{n} operating points; worst error per coefficient, in LSBs of Q4.{CF}:")
    for nm, (e, where) in zip(names, worst):
        print(f"  {nm:7s} {e:6.2f}   at dac, res_dac, mod_dac, tri, fc = {where}")
    bad = [nm for nm, (e, _) in zip(names, worst) if e > 2.0]
    print("PASS" if not bad else f"FAIL {bad} over 2 LSB")
    return 0 if not bad else 1


def cmd_emit(a):
    """rtl/sound/cem3394_coef.svh: the tables and constants cem3394_coef.sv uses."""
    out = REPO / "rtl" / "sound" / "cem3394_coef.svh"
    nl = chr(10)
    L = ["// GENERATED by scripts/cem3394_coef.py emit -- do not edit.", "",
         f"localparam logic [63:0] PK = 64'd{PK};",
         f"localparam logic [63:0] A_SIXTH = 64'd{A_SIXTH};", "",
         "function automatic logic [63:0] ptab(input logic [8:0] i);", "    case (i)"]
    L += [f"        9'd{i}: ptab = 64'd{v};" for i, v in enumerate(PTAB)]
    L += ["        default: ptab = '0;", "    endcase", "endfunction", "",
          "function automatic logic [63:0] rtab(input logic [8:0] i);", "    case (i)"]
    L += [f"        9'd{i}: rtab = 64'd{v};" for i, v in enumerate(RTAB)]
    L += ["        default: rtab = '0;", "    endcase", "endfunction"]
    out.write_text(nl.join(L) + nl, newline=nl)
    print(f"-> {out}")
    return 0


def cmd_vectors(a):
    """Random voice-samples through the mixer and the unit, for sim/coef_tb."""
    import random
    import cem3394_params as prm
    rng = random.Random(a.seed)
    lines = [f"# {a.n} voice-samples: inputs, then mix alpha beta0..3 alpha0"]
    one = 1 << F26
    for _ in range(a.n):
        w = [rng.randrange(-one - (one >> 3), one + (one >> 3)) for _ in range(4)]
        g = [rng.randrange(0, one >> 1) for _ in range(4)]
        fd = rng.choice([rng.randrange(4096), 0, 4095, 1100 + rng.randrange(600)])
        bm, be = prm.base_of_dac(fd)
        mh = prm.mod_half_of_dac(rng.choice([2048, rng.randrange(4096), 4095]))
        res = prm.res_of_dac(rng.choice([2048, rng.randrange(2048, 4096), 4095]))
        ramp, pulse, tri, ext = w
        mix = rnd(ramp * g[0] + pulse * g[1] + tri * g[2] + ext * g[3], F26)
        mix = max(-(1 << 29), min((1 << 29) - 1, mix))
        c = coeffs(*modulate(bm, be, mh, tri), res)
        lines.append(" ".join(str(v) for v in [ramp, pulse, tri, ext, *g, bm, be, mh, res, mix, *c]))
    nl = chr(10)
    open(a.out, "w", newline=nl).write(nl.join(lines) + nl)
    print(f"{a.n} vectors -> {a.out}")
    return 0


def cmd_tables(a):
    out = REPO / "rtl" / "sound"
    (out / "cem3394_ptab.hex").write_text("".join(f"{v:07x}\n" for v in PTAB))
    (out / "cem3394_rtab.hex").write_text("".join(f"{v:08x}\n" for v in RTAB))
    (out / "cem3394_ftab.hex").write_text(
        "".join(f"{(e & 0xff):02x}{m:07x}\n" for m, e in BASE))
    print(f"-> {out}/cem3394_{{ptab,rtab,ftab}}.hex")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--stride", type=int, default=7)
    c.set_defaults(fn=cmd_check)
    v = sub.add_parser("vectors")
    v.add_argument("--n", type=int, default=5000)
    v.add_argument("--seed", type=int, default=1)
    v.add_argument("--out", default="debug/cem3394/coef_vectors.txt")
    v.set_defaults(fn=cmd_vectors)
    e = sub.add_parser("emit")
    e.set_defaults(fn=cmd_emit)
    t = sub.add_parser("tables")
    t.set_defaults(fn=cmd_tables)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
