// SPDX-License-Identifier: GPL-3.0-or-later
//
// The 6VB's audio: six CEM3394 voices, the MM5837 noise source, the mix.
// scripts/sente6vb_audio.py is the specification, to the bit; sim/audio_tb
// checks this against it, driven by the control writes MAME's 6VB made.
//
// ONE INSTANCE OF EACH UNIT, SIX VOICES. The stages run concurrently on
// different voices, one-deep slots between them:
//
//   oscillator (cem3394_vco, NV=6)  ->  A  ->  mixer + coefficients
//   (cem3394_coef)  ->  B  ->  filter (cem3394_lpf4, NV=6)  ->  C  ->  output
//   (AC high-pass, final gain, accumulate)
//
// Each stage need only fit six voices into a sample -- the oscillator's
// measured worst is 60 cycles, the coefficients 42, the filter 41 -- rather
// than the chain fitting serially. A sample can still be finishing after the
// next tick, so everything that belongs to a sample (its noise value, the
// audio-enable bit, the voice's parameters) travels with the voice.
//
// `sample_tick` is 96 kHz on average from the parent; the parameters commit on
// it (sente6vb_params), so a control write reaches all six voices together.

module sente6vb_audio (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        sample_tick,

    input  logic        cv_valid,
    input  logic [5:0]  cv_mask,
    input  logic [2:0]  cv_reg,
    input  logic [11:0] cv_dac,
    input  logic        audio_en,         // counter-control bit 0

    output logic signed [15:0] sample,
    output logic        sample_valid,
    output logic [7:0]  late,             // ticks that found the last sample unfinished
    output logic [7:0]  param_overrun
);

    localparam logic [31:0] NSTEP   = 32'd773706146;   // 17.3 kHz noise clock at 96 kHz
    localparam logic [21:0] K_AC    = 22'd397;         // 11k, 10uF high-pass
    localparam logic [21:0] K_NOISE = 22'd288;         // 69k, 2.2uF high-pass
    localparam logic signed [63:0] DMAX = (64'sd1 <<< 29) - 64'sd1;
    localparam logic signed [63:0] DMIN = -(64'sd1 <<< 29);

    function automatic logic signed [63:0] rnd(input logic signed [63:0] x, input int sh);
        rnd = (x + (64'sd1 <<< (sh - 1))) >>> sh;
    endfunction
    function automatic logic signed [29:0] sat(input logic signed [63:0] v);
        sat = (v > DMAX) ? 30'(DMAX) : (v < DMIN) ? 30'(DMIN) : 30'(v);
    endfunction

    // ------------------------------------------------------------ parameters
    logic [2:0]  rd_voice;
    logic [31:0] p_step, p_inv, p_pw;
    logic [25:0] p_bm, p_res, p_gcomp;
    logic signed [7:0] p_be;
    logic [26:0] p_mod, p_gp, p_gs, p_gt, p_ge, p_gf;
    logic        p_busy;

    sente6vb_params u_params (
        .clk(clk), .rst_n(rst_n),
        .cv_valid(cv_valid), .cv_mask(cv_mask), .cv_reg(cv_reg), .cv_dac(cv_dac),
        .commit(sample_tick), .busy(p_busy), .overrun(param_overrun),
        .rd_voice(rd_voice),
        .step(p_step), .inv_step(p_inv), .pw(p_pw),
        .base_m(p_bm), .base_e(p_be), .mod_half(p_mod), .res(p_res), .gcomp(p_gcomp),
        .g_pulse(p_gp), .g_saw(p_gs), .g_tri(p_gt), .g_ext(p_ge), .g_final(p_gf)
    );

    // ---------------------------------------------------------------- noise
    // At each tick: the MM5837's shift register (18 bits as mm5837.h masks it,
    // output bit 16, taps 13 and 16), clocked by a phase
    // accumulator at 17.3 kHz, then its high-pass. Done before voice 0 starts.
    logic [17:0]        lfsr;
    logic               nbit;
    logic [31:0]        nacc;
    logic signed [63:0] nhp;              // the high-pass memory, 38 fraction bits
    logic signed [29:0] ext;
    logic               noise_ok;
    logic [1:0]         nph;
    logic signed [63:0] nd;

    // ------------------------------------------------------------ oscillator
    logic [2:0]         vk;               // next voice to launch this sample
    logic               sample_live;      // a tick has come and voices remain
    logic               en_s;             // audio_en at this sample's tick
    logic [31:0]        o_step, o_inv, o_pw;
    logic               vco_go, vco_done, vco_busy, vco_run;
    logic signed [29:0] v_ramp, v_pulse, v_tri;
    // what travels with the voice from the oscillator on
    typedef struct packed {
        logic [2:0]  voice;
        logic        en;
        logic signed [29:0] ext;
        logic [25:0] bm; logic signed [7:0] be;
        logic [26:0] mod;
        logic [25:0] res, gcomp;
        logic [26:0] gp, gs, gt, ge, gf;
    } vparam_t;
    vparam_t o_par;                       // the voice in the oscillator

    cem3394_vco #(.NV(6)) u_vco (
        .clk(clk), .rst_n(rst_n), .voice(o_par.voice),
        .step(o_step), .inv_step(o_inv), .pw(o_pw),
        .in_valid(vco_go), .out_valid(vco_done),
        .ramp(v_ramp), .pulse(v_pulse), .triang(v_tri), .busy(vco_busy)
    );

    // slot A: the oscillator's output
    logic               a_full;
    vparam_t            a_par;
    logic signed [29:0] a_ramp, a_pulse, a_tri;

    // ---------------------------------------------------------- coefficients
    logic               c_go, c_done, c_run;
    vparam_t            c_par;
    logic signed [29:0] c_ramp, c_pulse, c_tri;
    logic signed [29:0] c_mix;
    logic signed [25:0] c_alpha, c_b0, c_b1, c_b2, c_b3, c_a0;

    cem3394_coef u_coef (
        .clk(clk), .rst_n(rst_n), .start(c_go),
        .ramp(c_ramp), .pulse(c_pulse), .triang(c_tri), .ext(c_par.ext),
        .g_saw(c_par.gs), .g_pulse(c_par.gp), .g_tri(c_par.gt), .g_ext(c_par.ge),
        .base_m(c_par.bm), .base_e(c_par.be), .mod_half(c_par.mod), .res(c_par.res),
        .done(c_done), .mix(c_mix),
        .alpha(c_alpha), .beta0(c_b0), .beta1(c_b1), .beta2(c_b2), .beta3(c_b3), .alpha0(c_a0)
    );

    // slot B: mix and coefficients
    logic               b_full;
    vparam_t            b_par;
    logic signed [29:0] b_mix;
    logic signed [25:0] b_alpha, b_b0, b_b1, b_b2, b_b3, b_a0;

    // ---------------------------------------------------------------- filter
    logic               f_go, f_done, f_busy, f_run;
    vparam_t            f_par;
    logic signed [29:0] f_mix, f_out;
    logic signed [25:0] f_alpha, f_b0, f_b1, f_b2, f_b3, f_a0;

    cem3394_lpf4 #(.NV(6), .TANH_FILE("rtl/sound/cem3394_tanh.hex")) u_lpf (
        .clk(clk), .rst_n(rst_n), .voice(f_par.voice),
        .alpha(f_alpha), .beta0(f_b0), .beta1(f_b1), .beta2(f_b2), .beta3(f_b3),
        .alpha0(f_a0), .res(26'(f_par.res)), .gain_comp(26'(f_par.gcomp)),
        .in_valid(f_go), .in_sample(f_mix),
        .out_valid(f_done), .out_sample(f_out), .busy(f_busy)
    );

    // slot C: the filter's output
    logic               cc_full;
    vparam_t            cc_par;
    logic signed [29:0] cc_u;

    // ---------------------------------------------------------------- output
    logic signed [63:0] hp [0:5];         // each voice's AC high-pass memory
    logic signed [63:0] total;
    logic [2:0]         q;                // output stage step
    vparam_t            q_par;
    logic signed [63:0] qd;
    logic signed [29:0] qy;

    // one multiplier each for noise and output: operands in, product 2 later
    logic signed [63:0] nma, qma;
    logic signed [31:0] nmb, qmb;
    logic signed [95:0] nmp, qmp;
    always_ff @(posedge clk) begin
        nmp <= nma * nmb;
        qmp <= qma * qmb;
    end

    assign rd_voice = vk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr <= 18'h1ffff; nbit <= 1'b0; nacc <= '0; nhp <= '0; ext <= '0;
            noise_ok <= 1'b0; nph <= '0;
            vk <= '0; sample_live <= 1'b0; en_s <= 1'b0;
            vco_go <= 1'b0; vco_run <= 1'b0;
            a_full <= 1'b0; c_go <= 1'b0; c_run <= 1'b0; b_full <= 1'b0;
            f_go <= 1'b0; f_run <= 1'b0; cc_full <= 1'b0;
            for (int i = 0; i < 6; i++) hp[i] <= '0;
            total <= '0; q <= '0;
            sample <= '0; sample_valid <= 1'b0; late <= '0;
        end else begin
            vco_go <= 1'b0; c_go <= 1'b0; f_go <= 1'b0; sample_valid <= 1'b0;

            // ---------------------------------------------------- a new sample
            if (sample_tick) begin
                if (sample_live && late != 8'hff) late <= late + 8'd1;
                sample_live <= 1'b1;
                vk <= '0;
                en_s <= audio_en;
                noise_ok <= 1'b0;
                nph <= 2'd1;
                {nbit, nacc} <= {1'b0, nacc} + {1'b0, NSTEP};
            end

            // noise: clock the register on a carry, then the high-pass
            case (nph)
                2'd1: begin
                    if (nbit) begin                         // the accumulator carried
                        lfsr <= {lfsr[16:0], lfsr[13] ^ lfsr[16] ^ (lfsr == 18'd0)};
                    end
                    nph <= 2'd2;
                end
                2'd2: begin
                    nd  = ((64'(lfsr[16]) <<< 26) <<< 12) - nhp;
                    ext <= sat(rnd(nd, 12));
                    nma <= nd; nmb <= 32'(K_NOISE);
                    nph <= 2'd3;
                end
                2'd3: nph <= 2'd0;
                default: ;
            endcase
            if (nph == 2'd0 && !noise_ok && sample_live && !sample_tick) begin
                // two cycles after the operands: the product is ready
                nhp <= nhp + rnd(nmp[63:0], 22);
                noise_ok <= 1'b1;
            end

            // ---------------------------------------------- launch the oscillator
            if (sample_live && noise_ok && vk < 3'd6 && !vco_run && !a_full && !sample_tick) begin
                o_step <= p_step; o_inv <= p_inv; o_pw <= p_pw;
                o_par.voice <= vk;    o_par.en <= en_s;   o_par.ext <= ext;
                o_par.bm <= p_bm;     o_par.be <= p_be;   o_par.mod <= p_mod;
                o_par.res <= p_res;   o_par.gcomp <= p_gcomp;
                o_par.gp <= p_gp;     o_par.gs <= p_gs;   o_par.gt <= p_gt;
                o_par.ge <= p_ge;     o_par.gf <= p_gf;
                vco_go  <= 1'b1;
                vco_run <= 1'b1;
                vk <= vk + 3'd1;
                if (vk == 3'd5) sample_live <= 1'b0;
            end
            if (vco_done) begin
                a_full <= 1'b1; a_par <= o_par;
                a_ramp <= v_ramp; a_pulse <= v_pulse; a_tri <= v_tri;
                vco_run <= 1'b0;
            end

            // -------------------------------------------- launch the coefficients
            if (a_full && !c_run && !b_full) begin
                c_par <= a_par; c_ramp <= a_ramp; c_pulse <= a_pulse; c_tri <= a_tri;
                a_full <= 1'b0;
                c_go <= 1'b1; c_run <= 1'b1;
            end
            if (c_done) begin
                b_full <= 1'b1; b_par <= c_par; b_mix <= c_mix;
                b_alpha <= c_alpha; b_b0 <= c_b0; b_b1 <= c_b1; b_b2 <= c_b2;
                b_b3 <= c_b3; b_a0 <= c_a0;
                c_run <= 1'b0;
            end

            // ------------------------------------------------ launch the filter
            if (b_full && !f_run && !cc_full) begin
                f_par <= b_par; f_mix <= b_mix;
                f_alpha <= b_alpha; f_b0 <= b_b0; f_b1 <= b_b1; f_b2 <= b_b2;
                f_b3 <= b_b3; f_a0 <= b_a0;
                b_full <= 1'b0;
                f_go <= 1'b1; f_run <= 1'b1;
            end
            if (f_done) begin
                cc_full <= 1'b1; cc_par <= f_par; cc_u <= f_out;
                f_run <= 1'b0;
            end

            // ------------------------------------------------------ the output
            // y = u - mem; mem += (u - mem) k; out = y * final gain
            case (q)
                3'd0: if (cc_full) begin
                    q_par <= cc_par;
                    qd    <= (64'(cc_u) <<< 12) - hp[cc_par.voice];
                    cc_full <= 1'b0;
                    q <= 3'd1;
                end
                3'd1: begin
                    qy  <= sat(rnd(qd, 12));
                    qma <= qd; qmb <= 32'(K_AC);
                    q <= 3'd2;
                end
                3'd2: begin
                    qma <= 64'(qy); qmb <= 32'(q_par.gf);
                    q <= 3'd3;
                end
                3'd3: begin
                    hp[q_par.voice] <= hp[q_par.voice] + rnd(qmp[63:0], 22);
                    q <= 3'd4;
                end
                3'd4: begin
                    total <= total + 64'(sat(rnd(qmp[63:0], 26)));
                    q <= (q_par.voice == 3'd5) ? 3'd5 : 3'd0;
                end
                3'd5: begin
                    // six voices at 0.5 each, x 32768: round 12 bits off
                    if (!q_par.en)
                        sample <= '0;
                    else if (rnd(total, 12) > 64'sd32767)
                        sample <= 16'sd32767;
                    else if (rnd(total, 12) < -64'sd32768)
                        sample <= -16'sd32768;
                    else
                        sample <= 16'(rnd(total, 12));
                    sample_valid <= 1'b1;
                    total <= '0;
                    q <= 3'd0;
                end
                default: q <= 3'd0;
            endcase
        end
    end

endmodule
