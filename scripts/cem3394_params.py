#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The CEM3394's control-voltage conversions, in integers: what the core
computes when the sound CPU writes a DAC value to a voice register, and a
check of each against cem3394.cpp's floating-point setters.

    python scripts/cem3394_params.py check

Everything the voice needs from its eight registers, from the 12-bit DAC code
(cv = dac * 8/4096 - 4, sente6vb.cpp chip_select_w):

    step, inv_step   the oscillator's phase increment (Q0.32) and 2^52/step
                     (Q12.20), cem3394_vco's inputs. inv_step saturates below
                     about 23 Hz (DAC > ~3650), where it would need a 33rd bit;
                     no traced game goes below 27.5 Hz (docs/HACKS.md).
    pw               pulse width, Q0.32
    tri, saw         wave-select flags
    base             the filter's unmodulated cutoff / sample rate, as a Q1.25
                     mantissa and an exponent (scripts/cem3394_coef.py)
    mod_half         filter FM depth / 2, Q0.26
    res, gcomp       resonance and 1 + 0.2 res, Q4.22 (the filter's format)
    gains            pulse, saw, triangle, external and final gain, Q1.26

Exponentials go through one unit, `exp2`: 2^f = T[top 6 bits] * (1 + x ln2 (1 +
x ln2 / 2)) for the remaining bits x, three multiplies and a 64-entry table,
relative error about 1e-8. The dB curves are compute_db_volume's, as exponentials
of the voltage (and, below 2.5 V, of an exponential).
"""
import argparse
import math
import sys

F = 26                    # the fixed-point fraction used throughout
MF = 25                   # mantissa fraction, [1,2) as Q1.25
LN2 = round(math.log(2.0) * (1 << F))
T64 = [round(2.0 ** (i / 64.0) * (1 << F)) for i in range(64)]

SR = 96000.0
R_VCO, C_VCO, C_VCF = 301e3, 0.002e-6, 0.033e-6
Z_V = 1.3 / (5.0 * R_VCO * C_VCO)
Z_F = 4.3e-5 / C_VCF
PULSE_VOLUME = 0.25
SAWTOOTH_VOLUME = PULSE_VOLUME * 1.27
TRIANGLE_VOLUME = SAWTOOTH_VOLUME * 1.27
EXTERNAL_VOLUME = PULSE_VOLUME


def rnd(x, sh):
    return (x + (1 << (sh - 1))) >> sh if sh > 0 else x << (-sh)


def cfix(v, frac=F):
    """A constant, as the RTL holds it."""
    return round(v * (1 << frac))


def exp2(y):
    """2^(y / 2^F) for signed fixed-point y -> (Q1.25 mantissa, exponent)."""
    e = y >> F                               # floor
    f = y - (e << F)                         # [0, 1) in Q0.26
    hi = f >> (F - 6)
    x = f & ((1 << (F - 6)) - 1)             # [0, 1/64) in Q0.26
    xl = rnd(x * LN2, F)                     # x ln2
    poly = (1 << F) + rnd(xl * ((1 << F) + (xl >> 1)), F)
    m = rnd(T64[hi] * poly, F + F - MF)      # Q1.25 in [1, 2)
    if m >= (2 << MF):
        m >>= 1
        e += 1
    return m, e


def to_int(m, e, frac):
    """(Q1.25, exponent) -> integer with `frac` fraction bits, rounded."""
    sh = MF - e - frac
    return rnd(m, sh) if sh > 0 else m << (-sh)


def cv_fix(dac):
    """cv = dac/512 - 4, Q?.26 signed. Exact."""
    return (dac - 2048) << (F - 9)


# ----------------------------------------------------------------- oscillator
LOG2_STEP0 = cfix(math.log2(Z_V * 2.0 ** (4.0 / 0.75) / SR * 2.0 ** 32))
INV_384 = cfix(1.0 / 384.0, F + 9)           # dac/384 with 9 extra bits, then rounded


def step_of_dac(dac):
    y = LOG2_STEP0 - rnd(dac * INV_384, 9)
    s = to_int(*exp2(y), 0)
    return max(1, min(s, (1 << 32) - 1))


def inv_step_of_dac(dac):
    y = cfix(52.0) - (LOG2_STEP0 - rnd(dac * INV_384, 9))
    v = to_int(*exp2(y), 0)
    return min(v, (1 << 32) - 1)


def pw_of_dac(dac):
    """clamp(0.5*cv, 0, 1) as Q0.32 = clamp((dac - 2048)/1024)."""
    return max(0, min((1 << 32) - 1, (dac - 2048) << 22))


def wave_of_dac(dac):
    """(tri, saw): tri for -0.5 <= cv < 1.9, saw for cv >= 0.35."""
    return (1792 <= dac <= 3020, dac >= 2228)


# ---------------------------------------------------------------- the filter
LOG2_BASE0 = cfix(math.log2(Z_F * 2.0 ** (4.0 / 0.375) / SR))


def base_of_dac(dac):
    """filter_frequency / SR = B * 2^(-2 dac / 384), as (Q1.25, exponent)."""
    return exp2(LOG2_BASE0 - rnd(2 * dac * INV_384, 9))


MOD_K = cfix(0.5 * 1.98 / (3.5 - 0.01))


def mod_half_of_dac(dac):
    """filter_modulation / 2: 0.99 (cv - 0.01) / 3.49, clamped at cv < 0.01 and
    cv > 3.5. Q0.26."""
    cv = cv_fix(dac)
    if cv < cfix(0.01):
        return 0
    if cv > cfix(3.5):
        return cfix(0.99)
    return rnd((cv - cfix(0.01)) * MOD_K, F)


RES_K = cfix(4.0 / 2.5)


def res_of_dac(dac):
    """res = 4 cv / 2.5 for cv >= 0, Q4.22."""
    cv = cv_fix(dac)
    return 0 if cv < 0 else rnd(cv * RES_K, F + 4)


def gcomp_of_res(res):
    return (1 << 22) + rnd(res * cfix(0.2), F)


# ------------------------------------------------------------------ the gains
K_HI = cfix(40.0 / 3.0 / 20.0 * math.log2(10.0))    # 2.5..4 V: log2 gain per volt below 4
K_DB = cfix(math.log2(10.0) / 20.0)                  # log2 gain per dB
DB_MAX = cfix(90.0)


def db_volume(v):
    """compute_db_volume(v) for fixed-point volts, Q1.26."""
    if v >= cfix(4.0):
        return 1 << F
    if v <= 0:
        db = DB_MAX
    elif v >= cfix(2.5):
        return to_int(*exp2(-rnd((cfix(4.0) - v) * K_HI, F)), F)
    else:
        db = min(DB_MAX, 20 * to_int(*exp2(cfix(2.5) - v), F))
    return to_int(*exp2(-rnd(db * K_DB, F)), F)


def gains_of(mix_dac, gain_dac, tri, saw):
    """(pulse, saw, tri, ext, final) gains, Q1.26."""
    cv = cv_fix(mix_dac)
    if cv >= 0:
        mi = db_volume(cfix(3.55) - cv)
        me = db_volume(cfix(3.55) + rnd(cv * cfix(0.45 * 0.25), F))
    else:
        mi = db_volume(cfix(3.55) - rnd(cv * cfix(0.45 * 0.25), F))
        me = db_volume(cfix(3.55) + cv)
    return (rnd(mi * cfix(PULSE_VOLUME), F),
            rnd(mi * cfix(SAWTOOTH_VOLUME), F) if saw else 0,
            rnd(mi * cfix(TRIANGLE_VOLUME), F) if tri else 0,
            rnd(me * cfix(EXTERNAL_VOLUME), F),
            db_volume(cv_fix(gain_dac)))


# ------------------------------------------------------------- the reference
def compute_db(v):
    if v >= 4.0:
        return 0.0
    if v <= 0.0:
        return 90.0
    if v >= 2.5:
        return (4.0 - v) * (1.0 / 1.5) * 20.0
    return min(90.0, 20.0 * math.pow(2.0, 2.5 - v))


def compute_db_volume(v):
    return math.pow(0.891251, compute_db(v))


def cmd_check(a):
    worst = {}

    def note(name, err, where):
        if err > worst.get(name, (-1, None))[0]:
            worst[name] = (err, where)

    for dac in range(4096):
        cv = dac * 8.0 / 4096.0 - 4.0
        f = Z_V * 2.0 ** (-cv / 0.75)
        step_f = f / SR * 2.0 ** 32
        s = step_of_dac(dac)
        note("step (relative)", abs(s - step_f) / step_f, dac)
        inv_f = 2.0 ** 52 / step_f
        if inv_f < 2 ** 32:
            note("inv_step (relative)", abs(inv_step_of_dac(dac) - inv_f) / inv_f, dac)
        bm, be = base_of_dac(dac)
        base_f = Z_F * 2.0 ** (-cv / 0.375) / SR
        note("base (relative)", abs(bm / 2.0 ** MF * 2.0 ** be - base_f) / base_f, dac)
        mh = 0.0 if cv < 0.01 else 0.99 if cv > 3.5 else 0.99 * (cv - 0.01) / 3.49
        note("mod_half (Q0.26 LSB)", abs(mod_half_of_dac(dac) - mh * 2 ** F), dac)
        rf = 0.0 if cv < 0 else 4.0 * cv / 2.5
        note("res (Q4.22 LSB)", abs(res_of_dac(dac) - rf * 2 ** 22), dac)
        # gains: final gain at this cv, and mixer balance at this cv
        gf = compute_db_volume(cv)
        note("final gain (relative)", abs(db_volume(cv_fix(dac)) - gf * 2 ** F) / (gf * 2 ** F), dac)
        if cv >= 0:
            mi_f, me_f = compute_db_volume(3.55 - cv), compute_db_volume(3.55 + 0.45 * cv * 0.25)
        else:
            mi_f, me_f = compute_db_volume(3.55 - 0.45 * cv * 0.25), compute_db_volume(3.55 + cv)
        p, _, t, e, _ = gains_of(dac, 2048, True, False)
        note("pulse gain (relative)", abs(p - PULSE_VOLUME * mi_f * 2 ** F) / (PULSE_VOLUME * mi_f * 2 ** F), dac)
        note("ext gain (relative)", abs(e - EXTERNAL_VOLUME * me_f * 2 ** F) / (EXTERNAL_VOLUME * me_f * 2 ** F), dac)
    for k, (e, w) in worst.items():
        print(f"  {k:24s} {e:.3g}   at dac {w}")
    return 0


def cmd_emit(a):
    """rtl/sound/sente6vb_params.svh: every constant rtl/sound/sente6vb_params.sv
    uses and the reset values, so the RTL cannot drift from this file."""
    from pathlib import Path
    out = Path(__file__).resolve().parent.parent / "rtl" / "sound" / "sente6vb_params.svh"
    consts = {
        "L_STEP": LOG2_STEP0, "L_BASE": LOG2_BASE0, "C52": cfix(52.0),
        "INV_384": INV_384, "LN2": LN2, "MOD_K": MOD_K, "RES_K": RES_K,
        "K02": cfix(0.2), "K_HI": K_HI, "K_DB": K_DB,
        "K_PULSE": cfix(PULSE_VOLUME), "K_SAW": cfix(SAWTOOTH_VOLUME),
        "K_TRI": cfix(TRIANGLE_VOLUME), "K_EXT": cfix(EXTERNAL_VOLUME),
        "K045Q": cfix(0.45 * 0.25),
        "V4": cfix(4.0), "V25": cfix(2.5), "V355": cfix(3.55), "V001": cfix(0.01),
        "V35": cfix(3.5), "V099": cfix(0.99), "DB_MAX": DB_MAX,
    }
    step = step_of_dac(2048)
    inv = inv_step_of_dac(2048)
    bm, be = base_of_dac(2048)
    gp, gs, gt, ge, gf = gains_of(2048, 2048, *wave_of_dac(2048))
    cv = cv_fix(2048)
    mi = db_volume(cfix(3.55) - cv)
    me = db_volume(cfix(3.55) + rnd(cv * cfix(0.45 * 0.25), F))
    tri, saw = wave_of_dac(2048)
    reset = {
        "R_STEP": step, "R_INV": inv, "R_PW": pw_of_dac(2048), "R_BM": bm, "R_BE": be,
        "R_MOD": mod_half_of_dac(2048), "R_RES": res_of_dac(2048),
        "R_GCOMP": gcomp_of_res(res_of_dac(2048)), "R_MI": mi, "R_ME": me,
        "R_TRI": int(tri), "R_SAW": int(saw),
        "R_GP": gp, "R_GS": gs, "R_GT": gt, "R_GE": ge, "R_GF": gf,
    }
    lines = ["// GENERATED by scripts/cem3394_params.py emit -- do not edit.", ""]
    for k, v in consts.items():
        lines.append(f"localparam logic signed [39:0] {k} = {'-' if v < 0 else ''}40'sd{abs(v)};")
    lines.append("")
    lines.append("// Every voice's values after cem3394 device_reset (every CV at 0 V, DAC 2048).")
    for k, v in reset.items():
        lines.append(f"localparam logic signed [39:0] {k} = {'-' if v < 0 else ''}40'sd{abs(v)};")
    lines.append("")
    lines.append("function automatic logic [26:0] t64(input logic [5:0] i);")
    lines.append("    case (i)")
    for i, v in enumerate(T64):
        lines.append(f"        6'd{i}: t64 = 27'd{v};")
    lines.append("        default: t64 = '0;")
    lines.append("    endcase")
    lines.append("endfunction")
    nl = chr(10)
    out.write_text(nl.join(lines) + nl, newline=nl)
    print(f"-> {out}")
    return 0


def voice_params(d):
    """Everything rtl/sound/sente6vb_params.sv outputs for one voice's DAC codes."""
    tri, saw = wave_of_dac(d[7])
    bm, be = base_of_dac(d[3])
    res = res_of_dac(d[2])
    gp, gs, gt, ge, gf = gains_of(d[4], d[1], tri, saw)
    return [step_of_dac(d[0]), inv_step_of_dac(d[0]), pw_of_dac(d[6]), bm, be,
            mod_half_of_dac(d[5]), res, gcomp_of_res(res), gp, gs, gt, ge, gf]


def cmd_vectors(a):
    """Random writes and the parameters each should leave, for sim/params_tb."""
    import random
    rng = random.Random(a.seed)
    dacs = [[2048] * 8 for _ in range(6)]
    out = [f"# {a.n} writes"]
    for _ in range(a.n):
        mask = rng.choice([1, 2, 4, 8, 16, 32, rng.randrange(1, 64)])
        reg = rng.randrange(8)
        # the whole range, with the thresholds and ends visited on purpose
        dac = rng.choice([rng.randrange(4096), 0, 4095, 2048, 2047, 1792, 3020, 3021,
                          2227, 2228, 3328, 3072, 2049])
        out.append(f"W {mask} {reg} {dac}")
        for v in range(6):
            if mask >> v & 1:
                dacs[v][reg] = dac
                out.append("E " + str(v) + " " + " ".join(str(x) for x in voice_params(dacs[v])))
    nl = chr(10)
    open(a.out, "w", newline=nl).write(nl.join(out) + nl)
    print(f"{a.n} writes -> {a.out}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    vv = sub.add_parser("vectors")
    vv.add_argument("--n", type=int, default=2000)
    vv.add_argument("--seed", type=int, default=1)
    vv.add_argument("--out", default="debug/cem3394/params_vectors.txt")
    vv.set_defaults(fn=cmd_vectors)
    c = sub.add_parser("check")
    c.set_defaults(fn=cmd_check)
    e = sub.add_parser("emit")
    e.set_defaults(fn=cmd_emit)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
