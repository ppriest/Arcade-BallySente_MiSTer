// SPDX-License-Identifier: GPL-3.0-or-later
//
// Grudge Match's steering register at 0x9400, as balsente_m.cpp models it
// (update_grudge_steering, grudge_steering_r).
//
// A read sets bit 7 and returns the register with it set. While bit 7 is set,
// every main-CPU interrupt recomputes the register from the three wheel
// positions: for each wheel that moved since the last recompute, its low bit
// of the pair clears, and the high bit clears too if it moved up. The
// recompute starts from 0xFF, so bit 7 stays set: after the first read the
// register follows the wheels at every interrupt.
//
//   bits 1:0 wheel 0, 3:2 wheel 1, 5:4 wheel 2   (11 still, 10 down, 00 up)

module grudge_steering (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       tick,          // irq_timer, once per interrupt
    input  logic       rd,            // the CPU reads 0x9400
    input  logic [7:0] wheel0, wheel1, wheel2,
    output logic [7:0] q
);

    logic [7:0] result;
    logic [7:0] last [0:2];

    function automatic logic [1:0] pair(input logic [7:0] w, input logic [7:0] l);
        logic signed [7:0] d;
        d = signed'(w - l);
        pair = (d == 0) ? 2'b11 : (d > 0) ? 2'b00 : 2'b10;
    endfunction

    assign q = result | 8'h80;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result <= '0;
            last[0] <= '0; last[1] <= '0; last[2] <= '0;
        end else begin
            if (tick && result[7]) begin
                result  <= {2'b11, pair(wheel2, last[2]), pair(wheel1, last[1]),
                            pair(wheel0, last[0])};
                last[0] <= wheel0; last[1] <= wheel1; last[2] <= wheel2;
            end else if (rd) begin
                result[7] <= 1'b1;
            end
        end
    end

endmodule
