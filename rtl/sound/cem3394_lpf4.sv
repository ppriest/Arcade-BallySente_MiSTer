// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CEM3394's filter: MAME's va_lpf4, a Zavalishin TPT ladder. Four one-pole
// stages, a resonance feedback path with a tanh saturator, and low-frequency
// gain compensation. This is the only part of the voice with a feedback loop,
// so it is the part where fixed point can misbehave; docs/CEM3394_SPIKE.md has
// the measurements that chose the word width.
//
// ONE multiplier, shared: its operands are muxed by the step counter, the mux
// output is registered, and the raw product is registered, so the DSP has a
// cycle to itself. Twelve logical steps, three cycles each. A voice-sample at
// 96 kHz has about 417 clk_sys cycles at 40 MHz and six voices share them, so
// ~36 cycles per voice is ample.
//
// Sharing the multiplier is load-bearing and measured: writing the multiply
// inline in each state instead infers a separate multiplier per state -- 35 DSP
// blocks for one voice's filter, against 5 this way.
//
// The tanh saturator lives in tanh_lut.sv rather than here: inlined, its table
// was inferred as LUTs and the u_pre -> u path was this module's critical path,
// failing the -40C corner by 0.288 ns. get_timing_paths named it; two earlier
// guesses (the operand mux, then the mux feeding the DSP) were both wrong.
// See docs/LESSONS_LEARNED.md, "Ask the timing analyser which path fails".
//
// EVERY ARITHMETIC STEP MATCHES scripts/cem3394_model.py's fixed-point path to
// the bit, and sim/cem3394_lpf4_tb checks that against vectors the model emits.
// If you change rounding, saturation or the order of operations here, the bench
// fails -- that is the point. Do not "improve" the arithmetic without changing
// the model first.
//
//   rounding     round-half-up: (product + 2^(CW_FRAC-1)) >>> CW_FRAC
//   saturation   to the signed datapath range, after every operation
//
// Coefficients are inputs, computed per sample by rtl/sound/cem3394_coef.sv:
// the cutoff is frequency-modulated by the triangle, so they can change every
// sample.
//
// SHARED BY NV VOICES: the four stage states are an array indexed by `voice`,
// loaded when a sample starts and written back when it ends. NV = 1 is the
// single voice sim/cem3394_lpf4_tb checks.

module cem3394_lpf4 #(
    parameter int DW_INT     = 4,                   // integer bits, including sign
    parameter int DW_FRAC    = 26,
    parameter int DW         = DW_INT + DW_FRAC,
    // Coefficients are not all below 1: res reaches 4.8, gain_comp 1.96, and
    // alpha0 is exactly 1.0 with no resonance. CW_INT is their integer width
    // including sign -- one sign bit alone wraps 1.0 to -1.0.
    parameter int CW_INT     = 4,
    parameter int CW_FRAC    = 22,
    parameter int CW         = CW_INT + CW_FRAC,
    parameter int TANH_LOG2N = 10,
    parameter     TANH_FILE  = "tanh_table.hex",
    parameter int NV         = 1
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic [2:0]              voice,          // sampled with in_valid

    // Coefficients, held stable while busy.
    input  logic signed [CW-1:0]    alpha,          // G, the same for all four stages
    input  logic signed [CW-1:0]    beta0,
    input  logic signed [CW-1:0]    beta1,
    input  logic signed [CW-1:0]    beta2,
    input  logic signed [CW-1:0]    beta3,
    input  logic signed [CW-1:0]    alpha0,
    input  logic signed [CW-1:0]    res,
    input  logic signed [CW-1:0]    gain_comp,

    input  logic                    in_valid,       // one pulse per sample
    input  logic signed [DW-1:0]    in_sample,
    output logic                    out_valid,
    output logic signed [DW-1:0]    out_sample,
    output logic                    busy
);

    localparam int TANH_N     = 1 << TANH_LOG2N;
    // |x| >> TANH_SHIFT indexes the table and the low bits are the interpolation
    // fraction. The table spans [0, 4), so the index is |x| * 2^LOG2N / 4 --
    // a shift, not a multiply.
    localparam int TANH_SHIFT = DW_FRAC + 2 - TANH_LOG2N;
    localparam int ACC        = DW + 2;             // headroom for one add before saturating

    localparam logic signed [ACC-1:0] DMAX =  (ACC'(1) <<< (DW - 1)) - ACC'(1);
    localparam logic signed [ACC-1:0] DMIN = -(ACC'(1) <<< (DW - 1));

    // ---------------------------------------------------------------- state
    logic signed [DW-1:0] st0, st1, st2, st3;
    logic signed [DW-1:0] st0_m [0:NV-1], st1_m [0:NV-1], st2_m [0:NV-1], st3_m [0:NV-1];
    logic [2:0]           vi;
    logic signed [DW-1:0] sigma, x, u, u_pre;
    logic [3:0]           step;
    // Three cycles per step, each holding one piece of the path: select the
    // operand, multiply, round. Folding the operand mux in with the multiply
    // left the -40C corner 0.169 ns short.
    logic [1:0]           ph;
    logic                 running;

    assign busy = running;

    // --------------------------------------------------------------- helpers
    function automatic logic signed [DW-1:0] sat(input logic signed [ACC-1:0] v);
        if (v > DMAX)      sat = DMAX[DW-1:0];
        else if (v < DMIN) sat = DMIN[DW-1:0];
        else               sat = v[DW-1:0];
    endfunction

    // The rounding half of one multiply: round half-up back to the datapath,
    // then saturate. Matches Fixed.mul() in the model.
    function automatic logic signed [DW-1:0] round_sat(input logic signed [DW+CW-1:0] p);
        logic signed [DW+CW-1:0] r;
        begin
            r = (p + ((DW+CW)'(1) <<< (CW_FRAC - 1))) >>> CW_FRAC;
            if (r > (DW+CW)'(DMAX))      round_sat = DMAX[DW-1:0];
            else if (r < (DW+CW)'(DMIN)) round_sat = DMIN[DW-1:0];
            else                         round_sat = r[DW-1:0];
        end
    endfunction

    // ------------------------------------------------------------ tanh table
    logic                 tanh_start;
    logic                 tanh_done;
    logic signed [DW-1:0] tanh_y;

    tanh_lut #(.DW(DW), .LOG2N(TANH_LOG2N), .SHIFT(TANH_SHIFT), .FILE(TANH_FILE)) u_tanh (
        .clk(clk), .rst_n(rst_n),
        .start(tanh_start), .x(u_pre),
        .done(tanh_done), .y(tanh_y)
    );

    // ------------------------------------------------- the shared multiplier
    logic signed [DW-1:0]    mul_a;      // the mux output, combinational
    logic signed [DW-1:0]    mul_a_r;    // registered, so the DSP sees a flop
    logic signed [CW-1:0]    mul_b;
    logic signed [DW+CW-1:0] prod;
    logic signed [DW-1:0]    mul_y;

    always_comb begin
        case (step)
            4'd0:    begin mul_a = st0;                      mul_b = beta0;     end
            4'd1:    begin mul_a = st1;                      mul_b = beta1;     end
            4'd2:    begin mul_a = st2;                      mul_b = beta2;     end
            4'd3:    begin mul_a = st3;                      mul_b = beta3;     end
            4'd4:    begin mul_a = x;                        mul_b = gain_comp; end
            4'd5:    begin mul_a = sigma;                    mul_b = res;       end
            4'd6:    begin mul_a = x;                        mul_b = alpha0;    end
            4'd8:    begin mul_a = sat(ACC'(u) - ACC'(st0)); mul_b = alpha;     end
            4'd9:    begin mul_a = sat(ACC'(u) - ACC'(st1)); mul_b = alpha;     end
            4'd10:   begin mul_a = sat(ACC'(u) - ACC'(st2)); mul_b = alpha;     end
            4'd11:   begin mul_a = sat(ACC'(u) - ACC'(st3)); mul_b = alpha;     end
            default: begin mul_a = '0;                       mul_b = '0;        end
        endcase
    end

    assign mul_y = round_sat(prod);

    // ----------------------------------------------------------- the pipeline
    always_ff @(posedge clk or negedge rst_n) begin
        logic signed [DW-1:0] u_next;

        if (!rst_n) begin
            st0 <= '0; st1 <= '0; st2 <= '0; st3 <= '0; vi <= '0;
            for (int i = 0; i < NV; i++) begin
                st0_m[i] <= '0; st1_m[i] <= '0; st2_m[i] <= '0; st3_m[i] <= '0;
            end
            sigma <= '0; x <= '0; u <= '0; u_pre <= '0;
            prod <= '0; mul_a_r <= '0;
            tanh_start <= 1'b0;
            step <= 4'd0;
            ph <= 2'd0;
            running <= 1'b0;
            out_valid <= 1'b0;
            out_sample <= '0;
        end else begin
            out_valid  <= 1'b0;
            tanh_start <= 1'b0;
            mul_a_r    <= mul_a;
            prod       <= mul_a_r * mul_b;

            if (!running) begin
                if (in_valid) begin
                    x       <= in_sample;
                    vi      <= voice;
                    st0     <= st0_m[voice];
                    st1     <= st1_m[voice];
                    st2     <= st2_m[voice];
                    st3     <= st3_m[voice];
                    step    <= 4'd0;
                    ph      <= 2'd0;
                    running <= 1'b1;
                end
            end else if (step == 4'd7) begin
                // The lookup takes its own time; wait for it rather than
                // counting cycles.
                if (tanh_done) begin
                    u    <= tanh_y;
                    step <= 4'd8;
                    ph   <= 2'd0;
                end
            end else if (ph != 2'd2) begin
                ph <= ph + 2'd1;            // operand selecting, then multiplying
            end else begin
                ph <= 2'd0;
                case (step)
                    // sigma accumulates beta[i] * state[i], saturating at every
                    // add exactly as the model's fx.q(sigma + fx.mul()) does.
                    4'd0: begin sigma <= mul_y;                          step <= 4'd1;  end
                    4'd1: begin sigma <= sat(ACC'(sigma) + ACC'(mul_y)); step <= 4'd2;  end
                    4'd2: begin sigma <= sat(ACC'(sigma) + ACC'(mul_y)); step <= 4'd3;  end
                    4'd3: begin sigma <= sat(ACC'(sigma) + ACC'(mul_y)); step <= 4'd4;  end
                    // The model applies input_gain 1.0 and drive 1.0, so neither
                    // appears here as a multiply.
                    4'd4: begin x     <= mul_y;                          step <= 4'd5;  end
                    4'd5: begin x     <= sat(ACC'(x) - ACC'(mul_y));     step <= 4'd6;  end
                    // u_pre is registered here and the lookup starts on the
                    // next cycle, when it is stable.
                    4'd6: begin u_pre <= mul_y; tanh_start <= 1'b1;      step <= 4'd7;  end
                    // Four TPT stages: vn = (u - state) * G, which is mul_y;
                    // u = vn + state; state = vn + u.
                    4'd8: begin
                              u_next = sat(ACC'(mul_y) + ACC'(st0));
                              u   <= u_next;
                              st0 <= sat(ACC'(mul_y) + ACC'(u_next));
                              step <= 4'd9;
                          end
                    4'd9: begin
                              u_next = sat(ACC'(mul_y) + ACC'(st1));
                              u   <= u_next;
                              st1 <= sat(ACC'(mul_y) + ACC'(u_next));
                              step <= 4'd10;
                          end
                    4'd10: begin
                              u_next = sat(ACC'(mul_y) + ACC'(st2));
                              u   <= u_next;
                              st2 <= sat(ACC'(mul_y) + ACC'(u_next));
                              step <= 4'd11;
                          end
                    4'd11: begin
                              u_next = sat(ACC'(mul_y) + ACC'(st3));
                              u          <= u_next;
                              st3        <= sat(ACC'(mul_y) + ACC'(u_next));
                              st0_m[vi]  <= st0;
                              st1_m[vi]  <= st1;
                              st2_m[vi]  <= st2;
                              st3_m[vi]  <= sat(ACC'(mul_y) + ACC'(u_next));
                              out_sample <= u_next;
                              out_valid  <= 1'b1;
                              running    <= 1'b0;
                              step       <= 4'd0;
                          end
                    default: step <= 4'd0;
                endcase
            end
        end
    end

endmodule
