// SPDX-License-Identifier: GPL-3.0-or-later
//
// polyBLEP: the correction applied to a waveform either side of a step
// discontinuity, from MAME's va_vco.cpp via VCOFixed in
// scripts/cem3394_model.py, whose arithmetic this matches to the bit.
//
//   t = delta / step, as Q2.30, computed as delta * inv_step >> 22 so the
//       division becomes a multiply against a reciprocal the caller holds
//   t >= 0   the sample just after the discontinuity: t - t^2/2 - 1/2
//   t <  0   the sample just before it:               t + t^2/2 + 1/2
//
// Two multiplies, one at a time on a shared unit: four cycles per call.

module vco_blep #(
    parameter int PH_BITS  = 32,
    parameter int INV_FRAC = 20,
    parameter int T_FRAC   = 30,
    parameter int P_FRAC   = 26
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        start,
    input  logic signed [PH_BITS:0]     delta,      // signed: negative before the step
    input  logic        [PH_BITS-1:0]   inv_step,
    output logic                        done,
    output logic signed [P_FRAC+4:0]    val         // the datapath format
);

    localparam int TSH = PH_BITS + INV_FRAC - T_FRAC;   // 22
    localparam int PSH = T_FRAC - P_FRAC;               // 4

    logic [1:0]                      st;
    logic signed [PH_BITS+T_FRAC:0]  t;               // Q2.30
    logic signed [2*T_FRAC+1:0]      t2raw;

    always_ff @(posedge clk or negedge rst_n) begin
        logic signed [2*T_FRAC+1:0] p;
        logic signed [P_FRAC+4:0]   t_p, t2;

        if (!rst_n) begin
            st <= 2'd0; done <= 1'b0; val <= '0; t <= '0; t2raw <= '0;
        end else begin
            done <= 1'b0;
            case (st)
                2'd0: if (start) begin
                          p = delta * $signed({1'b0, inv_step});
                          t <= (p + (1 <<< (TSH - 1))) >>> TSH;
                          st <= 2'd1;
                      end
                2'd1: begin t2raw <= t * t;                     st <= 2'd2; end
                2'd2: begin
                          t_p = t >>> PSH;
                          // t^2 back into the output fraction
                          t2  = t2raw >>> (2 * T_FRAC - P_FRAC);
                          val  <= (t >= 0) ? (t_p - (t2 >>> 1) - (1 <<< (P_FRAC - 1)))
                                           : (t_p + (t2 >>> 1) + (1 <<< (P_FRAC - 1)));
                          done <= 1'b1;
                          st   <= 2'd0;
                      end
                default: st <= 2'd0;
            endcase
        end
    end

endmodule
