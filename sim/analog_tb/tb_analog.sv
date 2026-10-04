// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/analog_inputs.sv, directed: MiSTer's devices have no MAME capture, so
// this checks the descriptor semantics against MAME's port definitions by
// hand -- a relative port's value is its movement since the last vblank,
// PORT_REVERSE negates, sensitivity 50 halves, a stick is its position.
//
//   scripts/run_verilator.sh analog_tb
`timescale 1ns/1ps

module tb_analog;

    logic clk = 0;
    always #12.5 clk = ~clk;
    logic rst_n = 0;

    logic        vblank = 0;
    logic [31:0] port_cfg = '0;
    logic [24:0] ps2_mouse = '0;
    logic [15:0] stick0 = '0, stick1 = '0;
    logic [8:0]  spinner0 = '0, spinner1 = '0;
    logic [3:0]  dpad0 = '0, dpad1 = '0;          // U, D, L, R
    logic [7:0]  an0, an1, an2, an3;
    int          nbad = 0, nchk = 0;

    analog_inputs dut (.*);

    task automatic tick(int n = 1); repeat (n) @(posedge clk); endtask

    task automatic frame();
        vblank <= 1'b1; tick(3); vblank <= 1'b0; tick(3);
    endtask

    // A PS/2 packet: 9-bit signed dx, dy (+y up), [24] toggles.
    task automatic mouse(int dx, int dy);
        ps2_mouse[15:8]  <= 8'(dx); ps2_mouse[4] <= dx < 0;
        ps2_mouse[23:16] <= 8'(dy); ps2_mouse[5] <= dy < 0;
        ps2_mouse[24]    <= ~ps2_mouse[24];
        tick(2);
    endtask

    task automatic spin0(int d);
        spinner0 <= {~spinner0[8], 8'(d)}; tick(2);
    endtask

    task automatic check(string what, logic [7:0] got, int want);
        nchk++;
        if (got !== 8'(want)) begin
            nbad++;
            $display("FAIL %s: %0d, want %0d", what, $signed(got), want);
        end
    endtask

    initial begin
        tick(4); rst_n = 1; tick(2);

        // AN0 trackball X P1, AN1 trackball Y P1 reversed, AN2 dial P1 half,
        // AN3 stick X P2 reversed.
        port_cfg = {8'h80 | 8'(4 << 3) | 8'd1, 8'h40 | 8'(3 << 3), 8'h80 | 8'(2 << 3), 8'(1 << 3)};

        mouse(10, 4); mouse(7, -3);          // x 17, y +1 up -> screen -1
        spin0(6);
        stick1 = {8'd0, 8'd100};
        frame();
        check("tbX", an0, 17);
        check("tbY reversed", an1, 1);
        check("dial half", an2, (17 + 6) >>> 1);
        check("stick X reversed", an3, -100);

        // Relative ports read 0 once nothing moves; a stick holds.
        frame();
        check("tbX idle", an0, 0);
        check("dial idle", an2, 0);
        check("stick holds", an3, -100);

        // Clamp to a signed byte, and reverse of -128 stays in range.
        repeat (3) mouse(100, 0);
        frame();
        check("tbX clamp", an0, 127);
        repeat (3) mouse(0, -100);           // screen +300 -> clamp 127, reversed
        frame();
        check("tbY clamp reversed", an1, -127);
        stick1 = {8'd0, 8'h80};
        frame();
        check("stick -128 reversed", an3, 127);

        // A player 1 stick moves a trackball too, past its dead zone.
        stick0 = {8'd0, 8'd16};
        frame();
        check("stick in dead zone", an0, 0);
        stick0 = {8'd0, 8'd80};
        frame();
        check("stick as trackball", an0, 10);

        // The d-pad at 10 a frame (half MAME's key delta); down is +Y. AN1 is
        // player 1's trackball Y reversed, AN3 player 2's stick (no d-pad).
        stick0 = '0;
        dpad0 = 4'b0001;                     // right
        frame();
        check("d-pad right", an0, 10);
        check("d-pad right, dial half", an2, 5);
        dpad0 = 4'b0100;                     // down: +20, reversed
        frame();
        check("d-pad down reversed", an1, -10);
        dpad0 = 4'b0011;                     // left and right cancel
        frame();
        check("d-pad left+right", an0, 0);
        dpad0 = '0;

        // Sticks from the d-pad as MAME's AD_STICK keys: 20 a frame while held,
        // back toward centre by 20 once released, each axis on its own pair.
        // Shrike's layout: AN0 stick Y P1, AN1 stick X P1.
        port_cfg = {16'd0, 8'(4 << 3), 8'(5 << 3)};
        frame();
        dpad0 = 4'b1000;                     // up
        frame(); check("stick up 1", an0, -20); check("X still", an1, 0);
        frame(); check("stick up 2", an0, -40);
        repeat (4) frame();
        check("stick up 6", an0, -120);
        frame(); check("stick up clamp", an0, -128);
        dpad0 = 4'b0001;                     // up released, right held
        frame(); check("Y recentres", an0, -108); check("X right", an1, 20);
        dpad0 = 4'b0101;                     // down and right
        frame(); check("Y down", an0, -88); check("X right 2", an1, 40);
        dpad0 = '0;
        stick0 = {8'd30, 8'd0};              // the stick adds to the d-pad's
        frame(); check("Y stick + d-pad", an0, -68 + 30); check("X recentres", an1, 20);
        stick0 = '0;
        repeat (4) frame();
        check("Y centred", an0, 0); check("X centred", an1, 0);

        $display("%0d checks, %0d failures", nchk, nbad);
        if (nbad == 0) $display("PASS");
        else           $display("FAIL");
        $finish;
    end

endmodule
