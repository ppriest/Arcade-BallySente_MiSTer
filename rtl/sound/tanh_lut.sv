// SPDX-License-Identifier: GPL-3.0-or-later
//
// tanh(x) for the CEM3394 filter's feedback saturator, as a table with linear
// interpolation.
//
// Split out of cem3394_lpf4 because it was that module's critical path: with the
// table read, the interpolation and the arithmetic all in one cycle, and the
// table inferred as LUTs rather than block RAM, the -40C corner failed by
// 0.288 ns and the table cost most of the module's 1,669 ALMs
// (docs/LESSONS_LEARNED.md, "Ask the timing analyser which path fails").
//
// Here the table is a registered-read ROM, which is what Quartus needs to infer
// an M10K, and it is read on two consecutive cycles rather than duplicated, so
// one memory serves both taps. Six cycles per lookup. The filter has hundreds
// spare per sample, so the cycles are free and the logic is not.
//
// The arithmetic matches TanhLUT in scripts/cem3394_model.py exactly:
//   index       |x| >> SHIFT, clamped to N
//   fraction    the low SHIFT bits, unsigned
//   value       tab[i] + round_half_up((tab[i+1] - tab[i]) * frac)
//   sign        odd symmetry, applied last

module tanh_lut #(
    parameter int DW    = 30,
    parameter int LOG2N = 10,
    parameter int SHIFT = 18,     // DW_FRAC + 2 - LOG2N: the table spans [0, 4)
    parameter     FILE  = "tanh_table.hex"
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 start,      // sample x on this cycle
    input  logic signed [DW-1:0] x,
    output logic                 done,       // y is valid on this cycle
    output logic signed [DW-1:0] y
);

    localparam int N = 1 << LOG2N;

    // Registered read: the pattern Quartus infers an M10K from.
    logic signed [DW-1:0] rom [0:N];
    initial $readmemh(FILE, rom);

    logic [LOG2N:0]       addr;
    logic signed [DW-1:0] rom_q;
    always_ff @(posedge clk) rom_q <= rom[addr];

    logic [2:0]             st;
    logic                   neg;
    logic [SHIFT-1:0]       frac;
    logic [LOG2N:0]         idx;
    logic signed [DW-1:0]   t0, t1;
    logic signed [DW+SHIFT:0] prod;

    logic [DW-1:0] mag;
    assign mag = x[DW-1] ? (-x) : x;

    always_ff @(posedge clk or negedge rst_n) begin
        logic signed [DW+SHIFT:0] rnd;
        logic signed [DW-1:0]     sum;

        if (!rst_n) begin
            st <= 3'd0; done <= 1'b0; y <= '0;
            addr <= '0; neg <= 1'b0; frac <= '0; idx <= '0;
            t0 <= '0; t1 <= '0; prod <= '0;
        end else begin
            done <= 1'b0;
            case (st)
                3'd0: if (start) begin
                          neg <= x[DW-1];
                          // Beyond the table the value saturates: clamp the
                          // index and zero the fraction so the interpolation
                          // contributes nothing.
                          if (mag >= (DW'(N) <<< SHIFT)) begin
                              idx  <= (LOG2N+1)'(N);
                              frac <= '0;
                              addr <= (LOG2N+1)'(N);
                          end else begin
                              idx  <= mag[SHIFT+LOG2N-1 -: LOG2N];
                              frac <= mag[SHIFT-1:0];
                              addr <= mag[SHIFT+LOG2N-1 -: LOG2N];
                          end
                          st <= 3'd1;
                      end
                3'd1: begin
                          // rom_q is not ready until the next cycle; point the
                          // memory at the second tap meanwhile.
                          addr <= (idx == (LOG2N+1)'(N)) ? (LOG2N+1)'(N)
                                                         : (idx + (LOG2N+1)'(1));
                          st   <= 3'd2;
                      end
                3'd2: begin t0 <= rom_q;                       st <= 3'd3; end
                3'd3: begin t1 <= rom_q;                       st <= 3'd4; end
                3'd4: begin prod <= (t1 - t0) * signed'({1'b0, frac}); st <= 3'd5; end
                3'd5: begin
                          rnd = (prod + ((DW+SHIFT+1)'(1) <<< (SHIFT - 1))) >>> SHIFT;
                          sum = t0 + rnd[DW-1:0];
                          y    <= neg ? -sum : sum;
                          done <= 1'b1;
                          st   <= 3'd0;
                      end
                default: st <= 3'd0;
            endcase
        end
    end

endmodule
