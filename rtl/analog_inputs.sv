// SPDX-License-Identifier: GPL-3.0-or-later
//
// The four analog ports the ADC converts (MAME's AN0-AN3), made from MiSTer's
// mouse, analog sticks and spinners and latched once a frame at the start of
// vblank, as balsente_m.cpp update_analog_inputs() caches them.
//
// Each port has a descriptor byte from the .mra (scripts/build_mra.py):
//
//   [7]    reverse (MAME's PORT_REVERSE): the value is negated
//   [6]    half: MAME sensitivity 50 rather than 100
//   [5:3]  kind   0 none (reads 0)   1 trackball X   2 trackball Y
//                 3 dial             4 stick X       5 stick Y
//                 6 Stompin's pads, three to a port, from player 1's d-pad
//   [2]    not from the mouse (Night Stocker's dial: the mouse is the gun)
//   [1:0]  player; for kind 6 the pad row, 0 top, 1 middle, 2 bottom
//
// Trackballs and dials are relative (MAME's PORT_RESET): the movement since the
// last frame, clamped to a signed byte. Player 1's comes from the mouse; any
// player's also from its analog stick as a rate, and from its d-pad as MAME's
// default mapping does, down increasing Y, but at 10 a frame where MAME's
// PORT_KEYDELTA is 20: 20 was reported too fast on hardware (docs/HACKS.md);
// dials also take the spinner. Sticks are absolute, the position as a signed
// byte.
// MAME's screen Y grows downward and a PS/2 mouse's grows upward, so the
// mouse's Y is negated.

module analog_inputs (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        vblank,
    input  logic [31:0] port_cfg,       // one descriptor byte per port, AN0 low

    input  logic [24:0] ps2_mouse,      // [24] toggles; [23:16] dy, [15:8] dx, [5:4] signs
    input  logic [15:0] stick0,         // Y [15:8], X [7:0], -127..+127
    input  logic [15:0] stick1,
    input  logic [3:0]  dpad0,          // joystick bits 3:0: U, D, L, R
    input  logic [3:0]  dpad1,
    input  logic [8:0]  spinner0,       // [8] toggles; [7:0] -128..+127
    input  logic [8:0]  spinner1,

    output logic [7:0]  an0, an1, an2, an3
);

    logic signed [15:0] acc_mx, acc_my, acc_sp0, acc_sp1;
    logic               mt_d, s0_d, s1_d, vb_d;

    wire signed [15:0] mdx = {{8{ps2_mouse[4]}}, ps2_mouse[15:8]};
    wire signed [15:0] mdy = {{8{ps2_mouse[5]}}, ps2_mouse[23:16]};

    // A stick as a trackball: past a dead zone, an eighth of the deflection a frame.
    function automatic logic signed [15:0] rate(input logic [7:0] s);
        logic signed [15:0] v;
        v = 16'(signed'(s));
        rate = (v > 16 || v < -16) ? (v >>> 3) : 16'sd0;
    endfunction

    // A pair of d-pad directions: +10, -10 or 0.
    function automatic logic signed [15:0] keys(input logic inc, input logic dec);
        keys = (inc && !dec) ? 16'sd10 : (dec && !inc) ? -16'sd10 : 16'sd0;
    endfunction

    function automatic logic [7:0] port_value(input logic [7:0] c,
        input logic signed [15:0] mx, my, sp0, sp1, input logic [15:0] j0, j1,
        input logic [3:0] d0, d1);
        logic signed [15:0] v;
        logic signed [15:0] mxx, myy;
        logic [15:0] j;
        logic [3:0]  d;
        logic [1:0]  pl;
        logic        u, dn, l, r;
        pl = c[1:0];
        j  = (pl == 2'd0) ? j0 : (pl == 2'd1) ? j1 : 16'd0;
        d  = (pl == 2'd0) ? d0 : (pl == 2'd1) ? d1 : 4'd0;
        mxx = c[2] ? 16'sd0 : mx;
        myy = c[2] ? 16'sd0 : my;
        // Stompin: the eight pads are the d-pad's eight directions. Each port
        // carries three, active low in bits 7:5, the rest reading 1.
        {u, dn, l, r} = d0;
        if (c[5:3] == 3'd6) begin
            case (pl)
                2'd0:    port_value = {~(u && l), ~(u && !l && !r), ~(u && r), 5'h1f};
                2'd1:    port_value = {~(l && !u && !dn), 1'b1, ~(r && !u && !dn), 5'h1f};
                default: port_value = {~(dn && l), ~(dn && !l && !r), ~(dn && r), 5'h1f};
            endcase
            return port_value;
        end
        case (c[5:3])
            3'd1: v = ((pl == 2'd0) ? mxx : 16'sd0) + rate(j[7:0]) + keys(d[0], d[1]);
            3'd2: v = ((pl == 2'd0) ? myy : 16'sd0) + rate(j[15:8]) + keys(d[2], d[3]);
            3'd3: v = ((pl == 2'd0) ? mxx + sp0 : (pl == 2'd1) ? sp1 : 16'sd0) + rate(j[7:0])
                      + keys(d[0], d[1]);
            3'd4: v = 16'(signed'(j[7:0]));
            3'd5: v = 16'(signed'(j[15:8]));
            default: v = 16'sd0;
        endcase
        if (c[6]) v = v >>> 1;
        if (v > 16'sd127)  v = 16'sd127;
        if (v < -16'sd128) v = -16'sd128;
        if (c[7]) v = (v == -16'sd128) ? 16'sd127 : -v;
        port_value = v[7:0];
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_mx <= '0; acc_my <= '0; acc_sp0 <= '0; acc_sp1 <= '0;
            mt_d <= 1'b0; s0_d <= 1'b0; s1_d <= 1'b0; vb_d <= 1'b0;
            an0 <= '0; an1 <= '0; an2 <= '0; an3 <= '0;
        end else begin
            mt_d <= ps2_mouse[24];
            s0_d <= spinner0[8];
            s1_d <= spinner1[8];
            vb_d <= vblank;
            if (vblank && !vb_d) begin
                an0 <= port_value(port_cfg[7:0],   acc_mx, acc_my, acc_sp0, acc_sp1, stick0, stick1, dpad0, dpad1);
                an1 <= port_value(port_cfg[15:8],  acc_mx, acc_my, acc_sp0, acc_sp1, stick0, stick1, dpad0, dpad1);
                an2 <= port_value(port_cfg[23:16], acc_mx, acc_my, acc_sp0, acc_sp1, stick0, stick1, dpad0, dpad1);
                an3 <= port_value(port_cfg[31:24], acc_mx, acc_my, acc_sp0, acc_sp1, stick0, stick1, dpad0, dpad1);
                acc_mx <= '0; acc_my <= '0; acc_sp0 <= '0; acc_sp1 <= '0;
            end else begin
                if (ps2_mouse[24] != mt_d) begin
                    acc_mx <= acc_mx + mdx;
                    acc_my <= acc_my - mdy;
                end
                if (spinner0[8] != s0_d) acc_sp0 <= acc_sp0 + 16'(signed'(spinner0[7:0]));
                if (spinner1[8] != s1_d) acc_sp1 <= acc_sp1 + 16'(signed'(spinner1[7:0]));
            end
        end
    end

endmodule
