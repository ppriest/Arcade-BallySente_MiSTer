// SPDX-License-Identifier: GPL-3.0-or-later
//
// One voice-sample's mixer and filter coefficients.
//
// The mixer: the four waveforms times their gains, summed exactly and rounded
// once to Q4.26. The coefficients: the cutoff is frequency-modulated by this
// sample's triangle (cem3394.cpp's filt_fm), so va_lpf4's tan() and two
// divisions are needed every sample. scripts/cem3394_coef.py is the
// specification, to the bit, and explains the method; in short:
//
//   a      = base * (1 + (mod/2) tri), renormalised      (mantissa, exponent)
//   g      = a * P(a), P = tan(pi a)/a from a table, PK at and above 1/6
//   r      = 1/(1 + g)            reciprocal: table, interpolation, Newton
//   G      = g * r;  beta = (G^3 r, G^2 r, G r, r);  G^4
//   alpha0 = 1/(1 + res G^4)      the same reciprocal
//
// One multiplier; operands set in one state are in `mp` two states later, so
// independent products are issued back to back. Normalising (find the leading
// one, shift and round, fix a carry) takes three states of its own: done in
// one, with the variable shift before it, it was the whole design's critical
// path at -9.8 ns. About 54 cycles, against 69 a voice has in a 96 kHz sample
// at 40 MHz. Tables and constants come from
// scripts/cem3394_coef.py (emit).

module cem3394_coef (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,
    input  logic signed [29:0] ramp, pulse, triang, ext,   // Q4.26
    input  logic [26:0] g_saw, g_pulse, g_tri, g_ext,   // Q1.26
    input  logic [25:0] base_m,                         // Q1.25
    input  logic signed [7:0] base_e,
    input  logic [26:0] mod_half,                       // Q0.26
    input  logic [25:0] res,                            // Q4.22

    output logic        done,
    output logic signed [29:0] mix,                     // Q4.26
    output logic signed [25:0] alpha, beta0, beta1, beta2, beta3, alpha0   // Q4.22
);

`include "cem3394_coef.svh"

    localparam logic signed [79:0] DMAX = (80'sd1 <<< 29) - 80'sd1;
    localparam logic signed [79:0] DMIN = -(80'sd1 <<< 29);

    // ------------------------------------------------------------ helpers
    function automatic logic signed [79:0] rnd(input logic signed [79:0] x, input int sh);
        if (sh > 0) rnd = (x + (80'sd1 <<< (sh - 1))) >>> sh;
        else        rnd = x <<< (-sh);
    endfunction

    function automatic int topbit(input logic [79:0] v);
        topbit = -1;
        for (int i = 0; i < 80; i++) if (v[i]) topbit = i;
    endfunction

    // v (unsigned, `frac` fraction bits) -> {exponent[15:0], Q1.25 mantissa[26:0]}
    function automatic logic [42:0] normf(input logic [79:0] v, input int frac);
        int t, e, sh;
        logic [79:0] m;
        t  = topbit(v);
        e  = t - frac;
        sh = t - 25;
        m  = (sh > 0) ? 80'(rnd(signed'(v), sh)) : (v << (-sh));
        if (m >= (80'd1 << 26)) begin m = m >> 1; e = e + 1; end
        normf = {16'(e), m[26:0]};
    endfunction

    // (Q1.25, exponent) -> unsigned fixed with `frac` fraction bits
    function automatic logic signed [79:0] tofix(input logic [26:0] m, input int e, input int frac);
        tofix = rnd(80'(m), 25 - e - frac);
    endfunction

    function automatic logic signed [79:0] sat(input logic signed [79:0] v);
        sat = (v > DMAX) ? DMAX : (v < DMIN) ? DMIN : v;
    endfunction

    // ---------------------------------------------------------- multiplier
    logic signed [39:0] ma, mb;
    logic signed [79:0] mp;
    always_ff @(posedge clk) mp <= ma * mb;

    // --------------------------------------------------------------- state
    typedef enum logic [5:0] {
        S_IDLE,
        S_M1, S_M2, S_M3, S_M4, S_M5, S_M6, S_M7,
        S_A0, S_A0B, S_A1, S_A2, S_P0, S_P1, S_P2, S_G0, S_G1, S_G2,
        S_Y0, S_Y0B, S_Y0C, S_Y1,
        N_0, N_1, N_2,
        S_D0B,
        S_R0, S_R1, S_R2, S_R3, S_R4, S_R5, S_R6,
        S_B0, S_B1, S_B2, S_B3, S_B4, S_B5, S_B6, S_B7,
        S_D0, S_D1,
        S_DONE
    } state_t;
    state_t st, r_ret, n_ret;

    logic signed [79:0] acc, f;
    logic [26:0] a_m, g_m, y_m, d_m, rm_in;
    int          a_e, g_e, y_e, d_e;
    logic [79:0] a_fix;
    logic [8:0]  pidx;
    logic [79:0] p;
    logic signed [79:0] r0, rm, r, big_g, g2, b2;
    logic [8:0]  ridx;
    // the normalisation subroutine: in nv, nfrac; out nm, ne
    logic [79:0] nv, nm80;
    int          nfrac, nt, ne, shb;
    logic [26:0] nm;
    logic signed [79:0] yfix;

    always_ff @(posedge clk or negedge rst_n) begin
        logic signed [79:0] x;
        logic [42:0]        n;
        int                 sh;

        if (!rst_n) begin
            st <= S_IDLE; done <= 1'b0; ma <= '0; mb <= '0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                    ma <= 40'(ramp);  mb <= 40'(g_saw);   st <= S_M1;
                end
                // ------------------------------------------------ the mixer
                S_M1: begin ma <= 40'(pulse); mb <= 40'(g_pulse); st <= S_M2; end
                S_M2: begin acc <= mp;
                            ma <= 40'(triang);   mb <= 40'(g_tri);   st <= S_M3; end
                S_M3: begin acc <= acc + mp;
                            ma <= 40'(ext);   mb <= 40'(g_ext);   st <= S_M4; end
                S_M4: begin acc <= acc + mp;
                            ma <= 40'(mod_half); mb <= 40'(triang);  st <= S_M5; end
                S_M5: begin acc <= acc + mp; st <= S_M6; end
                S_M6: begin
                    mix <= 30'(sat(rnd(acc, 26)));
                    x = 80'sd67108864 + rnd(mp, 26);             // 1 + (mod/2) tri
                    if (x < 80'sd16384) x = 80'sd16384;          // fc stays positive
                    ma <= 40'(base_m); mb <= 40'(x);
                    st <= S_M7;
                end
                S_M7: st <= S_A0;
                // ------------------------------------------- a, then P(a)
                S_A0: begin nv <= mp; nfrac <= 51; n_ret <= S_A0B; st <= N_0; end
                S_A0B: begin
                    a_m <= nm;
                    a_e <= ne + int'(base_e);
                    st  <= S_A1;
                end
                S_A1: begin a_fix <= 80'(tofix(a_m, a_e, 32)); st <= S_A2; end
                S_A2: begin
                    x = signed'(a_fix);
                    if (a_e >= -2 || 80'(x) >= A_SIXTH) begin
                        p <= 80'(PK); st <= S_P2;
                    end else begin
                        pidx <= 9'(x >>> 22);
                        ma   <= 40'($signed(ptab(9'(x >>> 22) + 9'd1)) - $signed(ptab(9'(x >>> 22))));
                        mb   <= 40'(x & 80'h3fffff);
                        st   <= S_P0;
                    end
                end
                S_P0: st <= S_P1;
                S_P1: begin p <= 80'(ptab(pidx)) + 80'(rnd(mp, 22)); st <= S_P2; end
                S_P2: begin ma <= 40'(a_m); mb <= 40'(p); st <= S_G0; end
                S_G0: st <= S_G1;
                S_G1: begin nv <= mp; nfrac <= 49; n_ret <= S_G2; st <= N_0; end
                S_G2: begin
                    g_m <= nm;
                    g_e <= ne + a_e;
                    st  <= S_Y0;
                end
                // ------------------------------------------------ r = 1/(1+g)
                S_Y0:  begin yfix <= tofix(g_m, g_e, 40); st <= S_Y0B; end
                S_Y0B: begin
                    nv <= 80'((80'sd1 <<< 40) + yfix); nfrac <= 40; n_ret <= S_Y0C; st <= N_0;
                end
                S_Y0C: begin
                    y_m <= nm; y_e <= ne;
                    rm_in <= nm; r_ret <= S_Y1; st <= S_R0;
                end
                S_Y1: begin
                    r <= (y_e > 0) ? rnd(rm, y_e) : rm;
                    shb <= 25 - g_e + y_e;
                    ma <= 40'(g_m); mb <= 40'(rm);
                    st <= S_B0;
                end
                // ---------------------------------------- normalise (nv, nfrac)
                N_0: begin nt <= topbit(nv); st <= N_1; end
                N_1: begin
                    nm80 <= (nt - 25 > 0) ? 80'(rnd(signed'(nv), nt - 25)) : (nv << (25 - nt));
                    ne   <= nt - nfrac;
                    st   <= N_2;
                end
                N_2: begin
                    if (nm80 >= (80'd1 << 26)) begin nm <= 27'(nm80 >> 1); ne <= ne + 1; end
                    else                              nm <= 27'(nm80);
                    st <= n_ret;
                end
                // ------------------------------------------- the reciprocal
                // 1/m for a Q1.25 m in [1,2): table, interpolate, one Newton step
                S_R0: begin
                    ridx <= 9'((rm_in - 27'd33554432) >> 17);
                    ma <= 40'($signed(rtab(9'((rm_in - 27'd33554432) >> 17) + 9'd1))
                             - $signed(rtab(9'((rm_in - 27'd33554432) >> 17))));
                    mb <= 40'((rm_in - 27'd33554432) & 27'h1ffff);
                    st <= S_R1;
                end
                S_R1: st <= S_R2;
                S_R2: begin
                    x = 80'(rtab(ridx)) + rnd(mp, 17);
                    r0 <= x;
                    ma <= 40'(rm_in); mb <= 40'(x);
                    st <= S_R3;
                end
                S_R3: st <= S_R4;
                S_R4: begin
                    ma <= 40'(r0); mb <= 40'((80'sd2 <<< 26) - rnd(mp, 25));
                    st <= S_R5;
                end
                S_R5: st <= S_R6;
                S_R6: begin rm <= rnd(mp, 26); st <= r_ret; end
                // ------------------------------------------- G and the betas
                S_B0: st <= S_B1;
                S_B1: begin
                    x = rnd(mp, shb);
                    big_g <= x;
                    ma <= 40'(x); mb <= 40'(x);                  // G^2
                    st <= S_B2;
                end
                S_B2: begin ma <= 40'(big_g); mb <= 40'(r); st <= S_B3; end   // G r
                S_B3: begin
                    x = rnd(mp, 26); g2 <= x;
                    ma <= 40'(x); mb <= 40'(r);                  // G^2 r
                    st <= S_B4;
                end
                S_B4: begin
                    x = rnd(mp, 26); b2 <= x;
                    ma <= 40'(g2); mb <= 40'(g2);                // G^4
                    st <= S_B5;
                end
                S_B5: begin
                    beta1 <= 26'(rnd(rnd(mp, 26), 4));
                    ma <= 40'(g2); mb <= 40'(b2);                // G^3 r
                    st <= S_B6;
                end
                S_B6: begin
                    x = rnd(mp, 26);                             // G^4
                    ma <= 40'(res); mb <= 40'(x);
                    st <= S_B7;
                end
                S_B7: begin
                    beta0 <= 26'(rnd(rnd(mp, 26), 4));
                    st <= S_D0;
                end
                // --------------------------------- alpha0 = 1/(1 + res G^4)
                S_D0: begin
                    nv <= 80'(80'sd67108864 + rnd(mp, 22)); nfrac <= 26; n_ret <= S_D0B; st <= N_0;
                end
                S_D0B: begin
                    d_m <= nm; d_e <= ne;
                    rm_in <= nm; r_ret <= S_D1; st <= S_R0;
                end
                S_D1: begin
                    alpha0 <= 26'(rnd((d_e > 0) ? rnd(rm, d_e) : rm, 4));
                    alpha  <= 26'(rnd(big_g, 4));
                    beta2  <= 26'(rnd(b2, 4));
                    beta3  <= 26'(rnd(r, 4));
                    done   <= 1'b1;
                    st     <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
