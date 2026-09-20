// SPDX-License-Identifier: GPL-3.0-or-later
//
// polyBLAMP: the correction applied either side of a SLOPE discontinuity -- a
// triangle's corners, where the value is continuous but the derivative is not.
// From MAME's va_vco.cpp via VCOFixed in scripts/cem3394_model.py, whose
// arithmetic this matches to the bit.
//
//   x = delta / step, as Q2.30, in [0, 2)
//   u = 2 - x
//   y = -u^5,  and if the sample is within one step of the corner (`near`),
//       y += 4 * (1 - x)^5
//   result = y * step / 15
//
// The fifth powers go u2 = u*u, u4 = u2*u2, u5 = u4*u: three multiplies each,
// not four. Worst case nine multiplies (x, three for u, three for v, step,
// 1/15), one at a time on a shared unit.

module vco_blamp #(
    parameter int PH_BITS  = 32,
    parameter int INV_FRAC = 20,
    parameter int T_FRAC   = 30,
    parameter int P_FRAC   = 26
) (
    input  logic                        clk,
    input  logic                        rst_n,
    input  logic                        start,
    input  logic        [PH_BITS-1:0]   delta,
    input  logic                        near,       // MAME's `phase < m_step`
    input  logic        [PH_BITS-1:0]   inv_step,
    input  logic        [PH_BITS-1:0]   step,
    output logic                        done,
    output logic signed [P_FRAC+4:0]    val
);

    localparam int TSH     = PH_BITS + INV_FRAC - T_FRAC;   // 22
    localparam int PSH     = T_FRAC - P_FRAC;               // 4
    localparam int PW      = P_FRAC + 8;                    // room for u^5 <= 32
    // 1/15 as Q0.30, matching VCOFixed.RECIP15 exactly.
    localparam logic [30:0] RECIP15 = 31'((1 << 30) / 15 + 1);

    logic [3:0]                 st;
    logic signed [PW-1:0]       xq, u, v, acc, y;
    logic signed [2*PW-1:0]     mres;
    logic signed [PH_BITS+PW:0] tail;

    always_ff @(posedge clk or negedge rst_n) begin
        logic signed [PH_BITS+T_FRAC:0] t;

        if (!rst_n) begin
            st <= 4'd0; done <= 1'b0; val <= '0;
            xq <= '0; u <= '0; v <= '0; acc <= '0; y <= '0; mres <= '0; tail <= '0;
        end else begin
            done <= 1'b0;
            case (st)
                4'd0: if (start) begin
                          t = $signed({1'b0, delta}) * $signed({1'b0, inv_step});
                          t = (t + (1 <<< (TSH - 1))) >>> TSH;      // Q2.30
                          xq <= t >>> PSH;                          // Q.P_FRAC
                          st <= 4'd1;
                      end
                // u = 2 - x, then u^5
                4'd1: begin u <= (2 <<< P_FRAC) - xq;  st <= 4'd2; end
                4'd2: begin mres <= u * u;             st <= 4'd3; end   // u2
                4'd3: begin acc  <= mres >>> P_FRAC;   st <= 4'd4; end
                4'd4: begin mres <= acc * acc;         st <= 4'd5; end   // u4
                4'd5: begin acc  <= mres >>> P_FRAC;   st <= 4'd6; end
                4'd6: begin mres <= acc * u;           st <= 4'd7; end   // u5
                4'd7: begin
                          y  <= -(mres >>> P_FRAC);
                          v  <= (1 <<< P_FRAC) - xq;
                          st <= near ? 4'd8 : 4'd12;
                      end
                // v^5, only within one step of the corner
                4'd8:  begin mres <= v * v;            st <= 4'd9;  end
                4'd9:  begin acc  <= mres >>> P_FRAC;  st <= 4'd10; end
                4'd10: begin mres <= acc * acc;        st <= 4'd11; end
                4'd11: begin acc  <= mres >>> P_FRAC;  st <= 4'd14; end
                4'd14: begin mres <= acc * v;          st <= 4'd15; end
                4'd15: begin y <= y + 4 * (mres >>> P_FRAC); st <= 4'd12; end
                // y * step / 15
                4'd12: begin tail <= y * $signed({1'b0, step});  st <= 4'd13; end
                4'd13: begin
                          val  <= ((tail >>> PH_BITS) * $signed({1'b0, RECIP15})) >>> 30;
                          done <= 1'b1;
                          st   <= 4'd0;
                      end
                default: st <= 4'd0;
            endcase
        end
    end

endmodule
