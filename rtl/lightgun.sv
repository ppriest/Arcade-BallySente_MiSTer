// SPDX-License-Identifier: GPL-3.0-or-later
//
// Night Stocker's gun: MAME's FAKEX/FAKEY ports (0..255, 0x80 at the centre),
// which the board reads two bits at a time (game_board.sv), and a crosshair
// where the gun points, since the monitor has none.
//
// The controls follow the Seta core's Zombie Raid. The position is held, and
// moved by: the d-pad, two units a frame; player 1's left stick, absolutely
// (past a dead zone of 8); the mouse, relatively. The OSD's Gun stick option
// decides what the stick is: Auto, where a fully deflected axis (96 or more)
// moves like the d-pad and a partly deflected one aims; Aim, always aiming;
// D-pad, always moving. Axes are independent.
//
// MAME's crosshair spans the visible area, 256 x 240, for 0-255 on each axis,
// so Y is scaled by 15/16 on screen, then raised 16 lines to where the game
// lands the shot.

module lightgun (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        vblank,
    input  logic [24:0] ps2_mouse,
    input  logic [15:0] stick,           // Y [15:8], X [7:0], signed
    input  logic [3:0]  dpad,            // joystick bits 3:0: U, D, L, R
    input  logic [1:0]  mode,            // 0 Auto, 1 Aim, 2 D-pad
    input  logic        flip,
    input  logic [8:0]  hpos, vpos,      // the pixel being output
    output logic [7:0]  gun_x, gun_y,
    output logic        crosshair        // draw the crosshair at this pixel
);

    localparam logic [7:0] DEAD = 8'd8;
    localparam logic [7:0] FULL = 8'd96;

    function automatic logic [7:0] mag(input logic [7:0] v);
        mag = v[7] ? (8'd0 - v) : v;
    endfunction

    function automatic logic [7:0] clamp8(input logic signed [10:0] v);
        clamp8 = (v < 0) ? 8'd0 : (v > 11'sd255) ? 8'd255 : v[7:0];
    endfunction

    wire [7:0] ax = stick[7:0];
    wire [7:0] ay = stick[15:8];
    wire       lx = mag(ax) >= DEAD;
    wire       ly = mag(ay) >= DEAD;
    // which deflections read as a direction: all (D-pad), none (Aim), full (Auto)
    wire       dx = (mode == 2'd2) ? lx : (mode == 2'd1) ? 1'b0 : (mag(ax) >= FULL);
    wire       dy = (mode == 2'd2) ? ly : (mode == 2'd1) ? 1'b0 : (mag(ay) >= FULL);
    wire       up    = dpad[3] || ( ay[7] && dy);
    wire       down  = dpad[2] || (!ay[7] && dy);
    wire       left  = dpad[1] || ( ax[7] && dx);
    wire       right = dpad[0] || (!ax[7] && dx);

    logic mt_d, vb_d;
    wire  frame = vblank && !vb_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gun_x <= 8'h80; gun_y <= 8'h80; mt_d <= 1'b0; vb_d <= 1'b0;
        end else begin
            mt_d <= ps2_mouse[24];
            vb_d <= vblank;
            if (ps2_mouse[24] != mt_d) begin
                // PS/2 Y grows upward; the screen's grows downward
                gun_x <= clamp8(11'(gun_x) + 11'(signed'({ps2_mouse[4], ps2_mouse[15:8]})));
                gun_y <= clamp8(11'(gun_y) - 11'(signed'({ps2_mouse[5], ps2_mouse[23:16]})));
            end else begin
                if (left || right) begin
                    if (frame) gun_x <= clamp8(11'(gun_x) + (right ? 11'sd2 : 11'sd0)
                                                           - (left  ? 11'sd2 : 11'sd0));
                end else if (lx)
                    gun_x <= 8'h80 + ax;
                if (up || down) begin
                    if (frame) gun_y <= clamp8(11'(gun_y) + (down ? 11'sd2 : 11'sd0)
                                                           - (up   ? 11'sd2 : 11'sd0));
                end else if (ly)
                    gun_y <= 8'h80 + ay;
            end
        end
    end

    // Where on screen: y * 15/16, 16 lines up -- MAME's crosshair mapping put
    // it 16 lines below where the game lands the shot, a constant offset
    // (reported on hardware) -- then mirrored with the picture.
    wire [8:0] sx0 = {1'b0, gun_x};
    wire [8:0] y15 = {1'b0, gun_y} - {5'b0, gun_y[7:4]};
    wire [8:0] sy0 = (y15 < 9'd16) ? 9'd0 : y15 - 9'd16;
    wire [8:0] sx  = flip ? 9'd255 - sx0 : sx0;
    wire [8:0] sy  = flip ? 9'd239 - sy0 : sy0;

    function automatic logic near(input logic [8:0] a, input logic [8:0] c);
        near = (a + 9'd4 >= c) && (a <= c + 9'd4);
    endfunction

    assign crosshair = hpos < 9'd256 && vpos < 9'd240 &&
                       ((hpos == sx && near(vpos, sy)) || (vpos == sy && near(hpos, sx)));

endmodule
