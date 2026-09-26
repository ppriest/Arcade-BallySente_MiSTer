// SPDX-License-Identifier: GPL-3.0-or-later
//
// Grudge Match's three steering wheels as positions (MAME's AN0-AN2 dials,
// not PORT_RESET), for grudge_steering.sv, which reports only which way each
// moved between interrupts. Player 1's wheel follows the mouse; each player's
// follows its spinner, and its d-pad or left stick at a steady rate, one step
// every 16 lines, so a held direction moves the wheel at every interrupt.

module grudge_wheels (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        hblank,
    input  logic [24:0] ps2_mouse,
    input  logic [8:0]  spinner0, spinner1, spinner2,
    input  logic [3:0]  dpad0, dpad1, dpad2,      // U, D, L, R
    input  logic [7:0]  stick0_x, stick1_x, stick2_x,
    output logic [7:0]  wheel0, wheel1, wheel2
);

    logic       mt_d, s0_d, s1_d, s2_d, hb_d;
    logic [3:0] lines;

    // -1, 0 or +1 from the d-pad's left/right or the stick past a dead zone
    function automatic logic [7:0] step(input logic [3:0] d, input logic [7:0] sx);
        logic signed [7:0] x;
        x = signed'(sx);
        if ((d[0] && !d[1]) || x > 16)  step = 8'd1;
        else if ((d[1] && !d[0]) || x < -16) step = 8'hff;
        else step = 8'd0;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wheel0 <= '0; wheel1 <= '0; wheel2 <= '0;
            mt_d <= 1'b0; s0_d <= 1'b0; s1_d <= 1'b0; s2_d <= 1'b0; hb_d <= 1'b0;
            lines <= '0;
        end else begin
            logic [7:0] a0, a1, a2;
            a0 = '0; a1 = '0; a2 = '0;
            mt_d <= ps2_mouse[24];
            s0_d <= spinner0[8]; s1_d <= spinner1[8]; s2_d <= spinner2[8];
            hb_d <= hblank;
            if (ps2_mouse[24] != mt_d) a0 = a0 + ps2_mouse[15:8];
            if (spinner0[8] != s0_d)   a0 = a0 + spinner0[7:0];
            if (spinner1[8] != s1_d)   a1 = a1 + spinner1[7:0];
            if (spinner2[8] != s2_d)   a2 = a2 + spinner2[7:0];
            if (hblank && !hb_d) begin
                lines <= lines + 4'd1;
                if (lines == 4'd0) begin
                    a0 = a0 + step(dpad0, stick0_x);
                    a1 = a1 + step(dpad1, stick1_x);
                    a2 = a2 + step(dpad2, stick2_x);
                end
            end
            wheel0 <= wheel0 + a0;
            wheel1 <= wheel1 + a1;
            wheel2 <= wheel2 + a2;
        end
    end

endmodule
