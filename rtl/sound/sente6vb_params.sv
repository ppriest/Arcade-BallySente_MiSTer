// SPDX-License-Identifier: GPL-3.0-or-later
//
// The six CEM3394s' control registers, and what each voice needs from them.
// scripts/cem3394_params.py is the specification, to the bit: its constants
// and reset values are generated into sente6vb_params.svh, and every rounding
// here is its rnd() (round half up, arithmetic shift).
//
// When the sound CPU latches a control voltage (sente6vb_io's cv_valid, one
// chip or several), each chip it reaches becomes a job for one sequential unit
// with one multiplier. A job recomputes only what its register feeds:
//
//   0  VCO frequency   step = 2^(L_STEP - dac/384), inv_step = 2^(52 - that)
//   1  final gain      compute_db_volume(cv)
//   2  resonance       res = 1.6 cv (cv >= 0), gcomp = 1 + 0.2 res
//   3  filter freq     base = 2^(L_BASE - 2 dac/384), mantissa and exponent
//   4  mixer balance   the internal and external mixer levels, then the gains
//   5  modulation      filter FM depth / 2
//   6  pulse width     clamp((dac - 2048)/1024), Q0.32
//   7  wave select     the triangle and sawtooth flags, then the gains
//
// Exponentials go through the EXP2 subroutine: 2^f = T[top 6 bits] *
// (1 + x ln2 (1 + x ln2/2)), three multiplies. compute_db_volume (DBV) is an
// exp2 of a linear function of the voltage above 2.5 V and, below it, an exp2
// of 20 times an exp2.
//
// TWO COPIES. Jobs write a staging copy; `commit`, pulsed at every sample
// tick, copies it to the active copy the voices read. So a write reaches all
// six voices at the same sample, as scripts/sente6vb_audio.py applies it, and a
// sample never mixes old and new values. A voice whose job is running at the
// tick keeps its active values until the next one.

module sente6vb_params (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        cv_valid,
    input  logic [5:0]  cv_mask,
    input  logic [2:0]  cv_reg,
    input  logic [11:0] cv_dac,

    input  logic        commit,
    output logic        busy,
    output logic [7:0]  overrun,          // writes that arrived with one queued

    input  logic [2:0]  rd_voice,
    output logic [31:0] step,
    output logic [31:0] inv_step,
    output logic [31:0] pw,
    output logic [25:0] base_m,           // Q1.25 in [1, 2)
    output logic signed [7:0] base_e,
    output logic [26:0] mod_half,         // Q0.26
    output logic [25:0] res,              // Q4.22, >= 0
    output logic [25:0] gcomp,            // Q4.22
    output logic [26:0] g_pulse,          // Q1.26
    output logic [26:0] g_saw,
    output logic [26:0] g_tri,
    output logic [26:0] g_ext,
    output logic [26:0] g_final
);

`include "sente6vb_params.svh"

    // ------------------------------------------------------------ per voice
    logic [31:0] r_step [0:5], r_inv [0:5], r_pw [0:5];
    logic [25:0] r_bm [0:5];
    logic signed [7:0] r_be [0:5];
    logic [26:0] r_mod [0:5];
    logic [25:0] r_res [0:5], r_gcomp [0:5];
    logic [26:0] r_mi [0:5], r_me [0:5];
    logic        r_tri [0:5], r_saw [0:5];
    logic [26:0] r_gp [0:5], r_gs [0:5], r_gt [0:5], r_ge [0:5], r_gf [0:5];

    // The active copy: what the voices read.
    logic [31:0] a_step [0:5], a_inv [0:5], a_pw [0:5];
    logic [25:0] a_bm [0:5];
    logic signed [7:0] a_be [0:5];
    logic [26:0] a_mod [0:5];
    logic [25:0] a_res [0:5], a_gcomp [0:5];
    logic [26:0] a_gp [0:5], a_gs [0:5], a_gt [0:5], a_ge [0:5], a_gf [0:5];

    assign step     = a_step[rd_voice];
    assign inv_step = a_inv[rd_voice];
    assign pw       = a_pw[rd_voice];
    assign base_m   = a_bm[rd_voice];
    assign base_e   = a_be[rd_voice];
    assign mod_half = a_mod[rd_voice];
    assign res      = a_res[rd_voice];
    assign gcomp    = a_gcomp[rd_voice];
    assign g_pulse  = a_gp[rd_voice];
    assign g_saw    = a_gs[rd_voice];
    assign g_tri    = a_gt[rd_voice];
    assign g_ext    = a_ge[rd_voice];
    assign g_final  = a_gf[rd_voice];

    // ------------------------------------------------------- the multiplier
    // Operands set in one state are in `mp` two states later: a state that
    // sets them is followed by a wait state, then the use.
    logic signed [39:0] ma, mb;
    logic signed [79:0] mp;
    always_ff @(posedge clk) mp <= ma * mb;

    function automatic logic signed [39:0] rnd(input logic signed [79:0] x, input int sh);
        logic signed [79:0] y;
        y = (x + (80'sd1 <<< (sh - 1))) >>> sh;
        rnd = y[39:0];
    endfunction

    function automatic logic signed [39:0] cv_of(input logic [11:0] d);
        cv_of = (40'(d) - 40'sd2048) <<< 17;
    endfunction

    // (Q1.25 mantissa, exponent) -> integer with `frac` fraction bits, rounded
    function automatic logic signed [39:0] to_int(input logic [26:0] m, input logic signed [9:0] e,
                                                  input int frac);
        int sh;
        sh = 25 - int'(e) - frac;
        if (sh > 0) to_int = 40'((({13'd0, m}) + (40'd1 << (sh - 1))) >> sh);
        else        to_int = 40'({13'd0, m}) << (-sh);
    endfunction

    function automatic logic [31:0] clamp32(input logic signed [39:0] v, input logic signed [39:0] lo);
        if (v < lo)                    clamp32 = 32'(lo);
        else if (v > 40'sd4294967295)  clamp32 = 32'hffffffff;
        else                           clamp32 = v[31:0];
    endfunction

    // ------------------------------------------------------------- the jobs
    logic        pend;
    logic [5:0]  pmask;
    logic [2:0]  preg;
    logic [11:0] pdac;

    typedef enum logic [5:0] {
        S_IDLE, S_NEXT, S_JOB,
        E_0, E_1, E_2, E_3, E_4, E_5, E_6, E_7,
        D_0, D_1, D_2, D_3, D_4, D_5, D_6, D_T,
        J0_1, J0_2, J0_3, J0_4,
        J1_1,
        J2_1, J2_2, J2_3, J2_4, J2_5,
        J3_1, J3_2, J3_3,
        J4_1, J4_2, J4_3, J4_4, J4_5, J4_6, J4_7,
        J5_1, J5_2,
        G_0, G_1, G_2, G_3, G_4, G_5, G_6, G_7, G_8
    } state_t;

    state_t st, e_ret, d_ret;
    logic [5:0]  todo;
    logic [2:0]  jv, jr;
    logic [11:0] jd;
    logic signed [39:0] jcv, t0;

    // EXP2: in ey; out em (Q1.25, normalised) and ee
    logic signed [39:0] ey, exl;
    logic signed [9:0]  ee;
    logic [25:0]        ef;
    logic [26:0]        em;
    // DBV: in dv; out dres (Q1.26)
    logic signed [39:0] dv, ddb;
    logic [26:0]        dres;

    assign busy = (st != S_IDLE) || pend;

    always_ff @(posedge clk or negedge rst_n) begin
        logic signed [39:0] x, m;
        logic [5:0]         lo;

        if (!rst_n) begin
            st <= S_IDLE; pend <= 1'b0; todo <= '0; overrun <= '0;
            ma <= '0; mb <= '0;
            for (int v = 0; v < 6; v++) begin
                r_step[v] <= 32'(R_STEP); r_inv[v] <= 32'(R_INV); r_pw[v] <= 32'(R_PW);
                r_bm[v] <= 26'(R_BM); r_be[v] <= 8'(R_BE); r_mod[v] <= 27'(R_MOD);
                r_res[v] <= 26'(R_RES); r_gcomp[v] <= 26'(R_GCOMP);
                r_mi[v] <= 27'(R_MI); r_me[v] <= 27'(R_ME);
                r_tri[v] <= R_TRI[0]; r_saw[v] <= R_SAW[0];
                r_gp[v] <= 27'(R_GP); r_gs[v] <= 27'(R_GS); r_gt[v] <= 27'(R_GT);
                r_ge[v] <= 27'(R_GE); r_gf[v] <= 27'(R_GF);
                a_step[v] <= 32'(R_STEP); a_inv[v] <= 32'(R_INV); a_pw[v] <= 32'(R_PW);
                a_bm[v] <= 26'(R_BM); a_be[v] <= 8'(R_BE); a_mod[v] <= 27'(R_MOD);
                a_res[v] <= 26'(R_RES); a_gcomp[v] <= 26'(R_GCOMP);
                a_gp[v] <= 27'(R_GP); a_gs[v] <= 27'(R_GS); a_gt[v] <= 27'(R_GT);
                a_ge[v] <= 27'(R_GE); a_gf[v] <= 27'(R_GF);
            end
        end else begin
            if (commit)
                for (int v = 0; v < 6; v++)
                    if (!(st != S_IDLE && st != S_NEXT && jv == 3'(v))) begin
                        a_step[v] <= r_step[v]; a_inv[v] <= r_inv[v]; a_pw[v] <= r_pw[v];
                        a_bm[v] <= r_bm[v]; a_be[v] <= r_be[v]; a_mod[v] <= r_mod[v];
                        a_res[v] <= r_res[v]; a_gcomp[v] <= r_gcomp[v];
                        a_gp[v] <= r_gp[v]; a_gs[v] <= r_gs[v]; a_gt[v] <= r_gt[v];
                        a_ge[v] <= r_ge[v]; a_gf[v] <= r_gf[v];
                    end

            if (cv_valid) begin
                if (pend && overrun != 8'hff) overrun <= overrun + 8'd1;
                pend <= 1'b1; pmask <= cv_mask; preg <= cv_reg; pdac <= cv_dac;
            end

            case (st)
                S_IDLE: if (pend && !cv_valid) begin
                    todo <= pmask; jr <= preg; jd <= pdac; jcv <= cv_of(pdac);
                    pend <= 1'b0;
                    st   <= S_NEXT;
                end

                // The lowest chip still to do.
                S_NEXT: begin
                    lo = todo & (~todo + 6'd1);
                    if (todo == '0) st <= S_IDLE;
                    else begin
                        todo <= todo & ~lo;
                        case (lo)
                            6'b000001: jv <= 3'd0;
                            6'b000010: jv <= 3'd1;
                            6'b000100: jv <= 3'd2;
                            6'b001000: jv <= 3'd3;
                            6'b010000: jv <= 3'd4;
                            default:   jv <= 3'd5;
                        endcase
                        st <= S_JOB;
                    end
                end

                S_JOB: case (jr)
                    3'd0: begin ma <= 40'(jd); mb <= INV_384; st <= J0_1; end
                    3'd1: begin dv <= jcv; d_ret <= J1_1; st <= D_0; end
                    3'd2: if (jcv < 0) begin
                              r_res[jv] <= '0; r_gcomp[jv] <= 26'd4194304; st <= S_NEXT;
                          end else begin
                              ma <= jcv; mb <= RES_K; st <= J2_1;
                          end
                    3'd3: begin ma <= 40'(jd) <<< 1; mb <= INV_384; st <= J3_1; end
                    3'd4: if (jcv >= 0) begin
                              dv <= V355 - jcv; d_ret <= J4_1; st <= D_0;
                          end else begin
                              ma <= jcv; mb <= K045Q; st <= J4_4;
                          end
                    3'd5: if (jcv < V001) begin
                              r_mod[jv] <= '0; st <= S_NEXT;
                          end else if (jcv > V35) begin
                              r_mod[jv] <= 27'(V099); st <= S_NEXT;
                          end else begin
                              ma <= jcv - V001; mb <= MOD_K; st <= J5_1;
                          end
                    3'd6: begin
                              if (jd <= 12'd2048)      r_pw[jv] <= '0;
                              else if (jd >= 12'd3072) r_pw[jv] <= 32'hffffffff;
                              else                     r_pw[jv] <= 32'(jd - 12'd2048) << 22;
                              st <= S_NEXT;
                          end
                    default: begin
                              r_tri[jv] <= (jd >= 12'd1792) && (jd <= 12'd3020);
                              r_saw[jv] <= (jd >= 12'd2228);
                              st <= G_0;
                          end
                endcase

                // ---------------------------------------- 0: VCO frequency
                J0_1: st <= J0_2;
                J0_2: begin
                    x = L_STEP - rnd(mp, 9);
                    t0 <= x; ey <= x; e_ret <= J0_3; st <= E_0;
                end
                J0_3: begin
                    r_step[jv] <= clamp32(to_int(em, ee, 0), 40'sd1);
                    ey <= C52 - t0; e_ret <= J0_4; st <= E_0;
                end
                J0_4: begin
                    r_inv[jv] <= clamp32(to_int(em, ee, 0), 40'sd0);
                    st <= S_NEXT;
                end

                // ------------------------------------------- 1: final gain
                J1_1: begin r_gf[jv] <= dres; st <= S_NEXT; end

                // -------------------------------------------- 2: resonance
                J2_1: st <= J2_2;
                J2_2: begin
                    x = rnd(mp, 30);
                    r_res[jv] <= 26'(x);
                    ma <= x; mb <= K02; st <= J2_3;
                end
                J2_3: st <= J2_4;
                J2_4: begin
                    r_gcomp[jv] <= 26'(40'sd4194304 + rnd(mp, 26));
                    st <= S_NEXT;
                end

                // -------------------------------------- 3: filter frequency
                J3_1: st <= J3_2;
                J3_2: begin ey <= L_BASE - rnd(mp, 9); e_ret <= J3_3; st <= E_0; end
                J3_3: begin
                    r_bm[jv] <= em[25:0]; r_be[jv] <= 8'(ee);
                    st <= S_NEXT;
                end

                // ----------------------------------------- 4: mixer balance
                // cv >= 0: mi = DBV(3.55 - cv), me = DBV(3.55 + 0.1125 cv)
                // cv <  0: mi = DBV(3.55 - 0.1125 cv), me = DBV(3.55 + cv)
                J4_1: begin
                    r_mi[jv] <= dres;
                    ma <= jcv; mb <= K045Q; st <= J4_2;
                end
                J4_2: st <= J4_3;
                J4_3: begin dv <= V355 + rnd(mp, 26); d_ret <= J4_6; st <= D_0; end
                J4_4: st <= J4_5;
                J4_5: begin dv <= V355 - rnd(mp, 26); d_ret <= J4_7; st <= D_0; end
                J4_7: begin                               // cv < 0: that was mi
                    r_mi[jv] <= dres;
                    dv <= V355 + jcv; d_ret <= J4_6; st <= D_0;
                end
                J4_6: begin r_me[jv] <= dres; st <= G_0; end

                // ------------------------------------------- 5: modulation
                J5_1: st <= J5_2;
                J5_2: begin r_mod[jv] <= 27'(rnd(mp, 26)); st <= S_NEXT; end

                // ------------------------------- the gains, from mi, me, flags
                G_0: begin ma <= 40'(r_mi[jv]); mb <= K_PULSE; st <= G_1; end
                G_1: begin ma <= 40'(r_mi[jv]); mb <= K_SAW;   st <= G_2; end
                G_2: begin ma <= 40'(r_mi[jv]); mb <= K_TRI;   st <= G_3;
                           r_gp[jv] <= 27'(rnd(mp, 26)); end
                G_3: begin ma <= 40'(r_me[jv]); mb <= K_EXT;   st <= G_4;
                           r_gs[jv] <= r_saw[jv] ? 27'(rnd(mp, 26)) : '0; end
                G_4: begin st <= G_5;
                           r_gt[jv] <= r_tri[jv] ? 27'(rnd(mp, 26)) : '0; end
                G_5: begin r_ge[jv] <= 27'(rnd(mp, 26)); st <= S_NEXT; end

                // ----------------------------------------------------- EXP2
                E_0: begin
                    ee <= 10'(ey >>> 26);
                    ef <= ey[25:0];
                    ma <= 40'(ey[19:0]); mb <= LN2;
                    st <= E_1;
                end
                E_1: st <= E_2;
                E_2: begin
                    x = rnd(mp, 26);                          // x ln2
                    exl <= x;
                    ma <= x; mb <= 40'sd67108864 + (x >>> 1);
                    st <= E_3;
                end
                E_3: st <= E_4;
                E_4: begin
                    ma <= 40'(t64(ef[25:20]));
                    mb <= 40'sd67108864 + rnd(mp, 26);        // the polynomial
                    st <= E_5;
                end
                E_5: st <= E_6;
                E_6: begin
                    m = rnd(mp, 27);
                    if (m >= 40'sd67108864) begin
                        em <= 27'(m >>> 1); ee <= ee + 10'sd1;
                    end else begin
                        em <= 27'(m);
                    end
                    st <= E_7;
                end
                E_7: st <= e_ret;

                // ------------------------------------------------------ DBV
                D_0: begin
                    if (dv >= V4) begin
                        dres <= 27'd67108864; st <= d_ret;
                    end else if (dv <= 0) begin
                        ddb <= DB_MAX; st <= D_4;
                    end else if (dv >= V25) begin
                        ma <= V4 - dv; mb <= K_HI; st <= D_1;
                    end else begin
                        ey <= V25 - dv; e_ret <= D_3; st <= E_0;
                    end
                end
                D_1: st <= D_2;
                D_2: begin ey <= -rnd(mp, 26); e_ret <= D_T; st <= E_0; end
                D_3: begin
                    x = to_int(em, ee, 26);
                    x = (x <<< 4) + (x <<< 2);                // x 20
                    ddb <= (x > DB_MAX) ? DB_MAX : x;
                    st <= D_4;
                end
                D_4: begin ma <= ddb; mb <= K_DB; st <= D_5; end
                D_5: st <= D_6;
                D_6: begin ey <= -rnd(mp, 26); e_ret <= D_T; st <= E_0; end
                D_T: begin dres <= 27'(to_int(em, ee, 26)); st <= d_ret; end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
