// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CEM3394's oscillator: MAME's va_vco configured as cem3394.cpp does --
// pulse derived from the triangle, pulse DC compensation on, no hard sync.
// Bit-exact against VCOFixed in scripts/cem3394_model.py, which is the port of
// MAME; sim/cem3394_vco_tb checks that.
//
// The phase accumulator IS a 32-bit counter, and `step` is the frequency as
// Q0.32. The anti-aliasing kernels divide by `step`, so the caller supplies
// `inv_step` -- a reciprocal recomputed only when the frequency changes, which
// is at CPU-write rate -- and the kernels multiply.
//
// Three waveforms, each corrected at its own discontinuities:
//   ramp      one step discontinuity, at the wrap             -> polyBLEP
//   pulse     two step discontinuities (it is the triangle
//             thresholded, so they move with the pulse width) -> polyBLEP
//   triangle  two SLOPE discontinuities, its corners          -> polyBLAMP
//
// Each correction is applied twice: to the sample before the discontinuity and
// to the one after. The "after" halves are carried in *_corr to the next
// sample, exactly as MAME carries m_ramp_correction and its siblings.
//
// SHARED BY NV VOICES. The state a voice carries from one sample to the next --
// the phase and the three corrections -- is an array indexed by `voice`, read
// when a sample starts and written back when it ends (docs/STATE.md: per-voice
// state must stay addressable). step, inv_step and pw are the voice's own and
// must be held while busy. NV = 1 is the single voice sim/cem3394_vco_tb checks.
//
// Worst case six polyBLEP calls and four polyBLAMP calls in one sample, which
// is 6*4 + 4*13 = 76 cycles. A 96 kHz sample is 417 clk_sys cycles at 40 MHz
// shared between six voices, so this is the part of the voice to watch; see
// docs/CEM3394_SPIKE.md for the cycle budget.

module cem3394_vco #(
    parameter int PH_BITS  = 32,
    parameter int INV_FRAC = 20,
    parameter int T_FRAC   = 30,
    parameter int P_FRAC   = 26,
    parameter int DW       = P_FRAC + 4,
    parameter int NV       = 1
) (
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic [2:0]                voice,       // sampled with in_valid

    input  logic [PH_BITS-1:0]        step,        // frequency, Q0.32
    input  logic [PH_BITS-1:0]        inv_step,    // 1/step, Q12.20
    input  logic [PH_BITS-1:0]        pw,          // pulse width, Q0.32

    input  logic                      in_valid,    // one pulse per sample
    output logic                      out_valid,
    output logic signed [DW-1:0]      ramp,
    output logic signed [DW-1:0]      pulse,
    output logic signed [DW-1:0]      triang,
    output logic                      busy
);

    localparam int PSH = PH_BITS - P_FRAC;         // 6
    // Quartus 17.0 will not parse a unary minus in front of a size cast
    // (-DW'(...)), so 1.0 in the output format is a named constant.
    localparam logic signed [DW-1:0] ONE_Q = DW'(1) <<< P_FRAC;

    logic [PH_BITS-1:0] phase_m [0:NV-1];
    logic [2:0]         vi;
    logic [PH_BITS-1:0] p, tp_reset, tp_flip, tritop;

    // The corrections carried into the next sample.
    logic signed [DW-1:0] ramp_corr, pulse_corr, triang_corr;
    logic signed [DW-1:0] ramp_corr_m [0:NV-1], pulse_corr_m [0:NV-1], triang_corr_m [0:NV-1];
    logic signed [DW-1:0] cur_r, nxt_r, cur_p, nxt_p, cur_t, nxt_t;

    // --------------------------------------------------------------- kernels
    logic                      blep_start, blep_done;
    logic signed [PH_BITS:0]   blep_delta;
    logic signed [DW-1:0]      blep_val;

    vco_blep #(.PH_BITS(PH_BITS), .INV_FRAC(INV_FRAC), .T_FRAC(T_FRAC), .P_FRAC(P_FRAC))
    u_blep (.clk(clk), .rst_n(rst_n), .start(blep_start), .delta(blep_delta),
            .inv_step(inv_step), .done(blep_done), .val(blep_val));

    logic                      blamp_start, blamp_done, blamp_near;
    logic [PH_BITS-1:0]        blamp_delta;
    logic signed [DW-1:0]      blamp_val;

    vco_blamp #(.PH_BITS(PH_BITS), .INV_FRAC(INV_FRAC), .T_FRAC(T_FRAC), .P_FRAC(P_FRAC))
    u_blamp (.clk(clk), .rst_n(rst_n), .start(blamp_start), .delta(blamp_delta),
             .near(blamp_near), .inv_step(inv_step), .step(step),
             .done(blamp_done), .val(blamp_val));

    // ------------------------------------------------------- naive waveforms
    // (2*ph - 2^32) >>> PSH, which is (ph - 2^31) >>> (PSH-1) exactly, both
    // being floor shifts. Writing it the first way needs 34 bits and is easy to
    // get wrong by one place -- which it was.
    function automatic logic signed [DW-1:0] naive_ramp(input logic [PH_BITS-1:0] ph);
        logic signed [PH_BITS:0] d;
        begin
            d = $signed({1'b0, ph}) - $signed({2'b01, {(PH_BITS-1){1'b0}}});
            naive_ramp = DW'(d >>> (PSH - 1));
        end
    endfunction

    function automatic logic signed [DW-1:0] naive_triang(input logic [PH_BITS-1:0] ph);
        logic signed [DW-1:0] r;
        begin
            r = naive_ramp(ph);
            naive_triang = ONE_Q - (r >= 0 ? (r <<< 1) : ((-r) <<< 1));
        end
    endfunction

    // The pulse is the triangle core thresholded, with DC compensation:
    // (pw > phase ? +1 : -1) - (2*pw - 1).
    function automatic logic signed [DW-1:0] naive_pulse(input logic [PH_BITS-1:0] ph);
        logic signed [DW-1:0] w;
        begin
            w = (ph < pw) ? ONE_Q : -ONE_Q;
            naive_pulse = w - naive_ramp(pw);
        end
    endfunction

    function automatic logic signed [DW-1:0] naive_tripulse(input logic [PH_BITS-1:0] ph);
        naive_tripulse = naive_pulse(ph + (pw >> 1));
    endfunction

    function automatic logic will_wrap(input logic [PH_BITS-1:0] ph);
        will_wrap = ph > ({PH_BITS{1'b1}} - step + {{(PH_BITS-1){1'b0}}, 1'b1});
    endfunction

    // ------------------------------------------------------------- sequencer
    // Each job is (which kernel, which delta, which accumulator, what sign).
    typedef enum logic [4:0] {
        S_IDLE,
        S_R0, S_R1,                       // ramp, the wrap, this sample and next
        S_P0, S_P1, S_P2, S_P3,           // pulse, reset up and flip down
        S_T0, S_T1, S_T2, S_T3,           // triangle, bottom corner and top
        S_DONE
    } state_t;

    state_t st;
    logic   issued;
    logic   do_reset, do_tpr, do_tpf, do_tritop;

    assign busy = (st != S_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        logic [PH_BITS-1:0] phase;

        if (!rst_n) begin
            st <= S_IDLE; issued <= 1'b0; out_valid <= 1'b0; vi <= '0;
            for (int i = 0; i < NV; i++) begin
                phase_m[i] <= '0; ramp_corr_m[i] <= '0;
                pulse_corr_m[i] <= '0; triang_corr_m[i] <= '0;
            end
            ramp_corr <= '0; pulse_corr <= '0; triang_corr <= '0;
            ramp <= '0; pulse <= '0; triang <= '0;
            blep_start <= 1'b0; blamp_start <= 1'b0;
        end else begin
            out_valid   <= 1'b0;
            blep_start  <= 1'b0;
            blamp_start <= 1'b0;

            case (st)
                S_IDLE: if (in_valid) begin
                    phase     = phase_m[voice];
                    vi          <= voice;
                    ramp_corr   <= ramp_corr_m[voice];
                    pulse_corr  <= pulse_corr_m[voice];
                    triang_corr <= triang_corr_m[voice];
                    p        <= phase;
                    tp_reset <= phase + (pw >> 1);
                    tp_flip  <= phase - (pw >> 1);
                    tritop   <= phase + {1'b1, {(PH_BITS-1){1'b0}}};
                    do_reset  <= will_wrap(phase);
                    do_tpr    <= will_wrap(phase + (pw >> 1));
                    do_tpf    <= will_wrap(phase - (pw >> 1));
                    do_tritop <= will_wrap(phase + {1'b1, {(PH_BITS-1){1'b0}}});
                    cur_r <= '0; nxt_r <= '0;
                    cur_p <= '0; nxt_p <= '0;
                    cur_t <= '0; nxt_t <= '0;
                    issued <= 1'b0;
                    st <= S_R0;
                end

                // ---- ramp: one discontinuity, jump -2
                S_R0: if (!do_reset) st <= S_P0;
                      else if (!issued) begin
                          blep_delta <= {1'b1, p};            // signed 33-bit: p - 2^32
                          blep_start <= 1'b1; issued <= 1'b1;
                      end else if (blep_done) begin
                          cur_r <= -(blep_val <<< 1);
                          issued <= 1'b0; st <= S_R1;
                      end
                S_R1: if (!issued) begin
                          blep_delta <= {1'b0, p + step};
                          blep_start <= 1'b1; issued <= 1'b1;
                      end else if (blep_done) begin
                          nxt_r <= -(blep_val <<< 1);
                          issued <= 1'b0; st <= S_P0;
                      end

                // ---- pulse: reset (+2) and flip (-2)
                S_P0: if (!do_tpr) st <= S_P2;
                      else if (!issued) begin
                          blep_delta <= {1'b1, tp_reset};     // tp_reset - 2^32
                          blep_start <= 1'b1; issued <= 1'b1;
                      end else if (blep_done) begin
                          cur_p <= cur_p + (blep_val <<< 1);
                          issued <= 1'b0; st <= S_P1;
                      end
                S_P1: if (!issued) begin
                          blep_delta <= {1'b0, tp_reset + step};
                          blep_start <= 1'b1; issued <= 1'b1;
                      end else if (blep_done) begin
                          nxt_p <= nxt_p + (blep_val <<< 1);
                          issued <= 1'b0; st <= S_P2;
                      end
                S_P2: if (!do_tpf) st <= S_T0;
                      else if (!issued) begin
                          blep_delta <= {1'b1, tp_flip};      // tp_flip - 2^32
                          blep_start <= 1'b1; issued <= 1'b1;
                      end else if (blep_done) begin
                          cur_p <= cur_p - (blep_val <<< 1);
                          issued <= 1'b0; st <= S_P3;
                      end
                S_P3: if (!issued) begin
                          blep_delta <= {1'b0, tp_flip + step};
                          blep_start <= 1'b1; issued <= 1'b1;
                      end else if (blep_done) begin
                          nxt_p <= nxt_p - (blep_val <<< 1);
                          issued <= 1'b0; st <= S_T0;
                      end

                // ---- triangle: bottom corner (-1) and top corner (+1)
                S_T0: if (!do_reset) st <= S_T2;
                      else if (!issued) begin
                          blamp_delta <= (~p) + 1'b1;              // 2^32 - p
                          blamp_near  <= ((~p) + 1'b1) < step;
                          blamp_start <= 1'b1; issued <= 1'b1;
                      end else if (blamp_done) begin
                          cur_t <= cur_t - blamp_val;
                          issued <= 1'b0; st <= S_T1;
                      end
                S_T1: if (!issued) begin
                          blamp_delta <= p + step;
                          blamp_near  <= (p + step) < step;
                          blamp_start <= 1'b1; issued <= 1'b1;
                      end else if (blamp_done) begin
                          nxt_t <= nxt_t - blamp_val;
                          issued <= 1'b0; st <= S_T2;
                      end
                S_T2: if (!do_tritop) st <= S_DONE;
                      else if (!issued) begin
                          blamp_delta <= (~tritop) + 1'b1;
                          blamp_near  <= ((~tritop) + 1'b1) < step;
                          blamp_start <= 1'b1; issued <= 1'b1;
                      end else if (blamp_done) begin
                          cur_t <= cur_t + blamp_val;
                          issued <= 1'b0; st <= S_T3;
                      end
                S_T3: if (!issued) begin
                          blamp_delta <= tritop + step;
                          blamp_near  <= (tritop + step) < step;
                          blamp_start <= 1'b1; issued <= 1'b1;
                      end else if (blamp_done) begin
                          nxt_t <= nxt_t + blamp_val;
                          issued <= 1'b0; st <= S_DONE;
                      end

                S_DONE: begin
                    ramp  <= naive_ramp(p)      + ramp_corr  + cur_r;
                    pulse <= naive_tripulse(p)  + pulse_corr + cur_p;
                    triang   <= naive_triang(p)       + triang_corr   + cur_t;
                    ramp_corr_m[vi]   <= nxt_r;
                    pulse_corr_m[vi]  <= nxt_p;
                    triang_corr_m[vi] <= nxt_t;
                    phase_m[vi]       <= p + step;
                    out_valid  <= 1'b1;
                    st         <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
