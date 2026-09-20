// SPDX-License-Identifier: GPL-3.0-or-later
//
// The raster. One 40 MHz clk_sys, a counter tap for the 5 MHz pixel clock --
// 40/8 divides exactly, as every clock on this board does (docs/ROADMAP.md,
// "One 40 MHz clk_sys, every clock enable a counter tap").
//
// Geometry from balsente.h, through MAME's set_raw():
//
//   pixel clock  20 MHz / 4 = 5 MHz        HTOTAL  320   VTOTAL  264
//   visible      256 x 240                 HBEND     0   VBEND    16
//   H 15.625 kHz, V 59.19 Hz               HBSTART 256   VBSTART 256
//
// So x runs 0..319 with 0..255 visible, and y runs 0..263 with 16..255 visible.
// `row` is the visible line, y - VBEND, which is what indexes video RAM.
//
// WHERE THE SYNC PULSES SIT IS A GUESS. MAME's set_raw() carries no sync
// position -- it models blanking only -- and there is no schematic here. They
// are placed in the middle of each blanking interval, which is what a CRT wants
// and what the scaler locks to; it affects centring, not correctness, and the
// OSD's CRT offset covers the rest. docs/HACKS.md has the entry.

// The counters are 9 bits, so the geometry is too: an `int` parameter makes
// every comparison against them a 32-bit one, and the width warnings that
// produces drown the ones worth reading.
module video_timing #(
    parameter logic [8:0] HTOTAL  = 9'd320,
    parameter logic [8:0] HBSTART = 9'd256,
    parameter logic [8:0] HSSTART = 9'd272,   // middle of the 64-clock blanking
    parameter logic [8:0] HSEND   = 9'd304,
    parameter logic [8:0] VTOTAL  = 9'd264,
    parameter logic [8:0] VBEND   = 9'd16,
    parameter logic [8:0] VBSTART = 9'd256,
    parameter logic [8:0] VSSTART = 9'd258,   // middle of the 8-line blanking
    parameter logic [8:0] VSEND   = 9'd261
) (
    input  logic       clk,        // clk_sys, 40 MHz
    input  logic       rst_n,

    output logic       ce_pix,     // one cycle in eight: the 5 MHz pixel clock
    output logic [2:0] phase,      // position within the pixel, 0..7
    output logic [8:0] hcnt,       // 0..HTOTAL-1
    output logic [8:0] vcnt,       // 0..VTOTAL-1
    output logic [7:0] row,        // visible line, vcnt - VBEND
    output logic       hblank,
    output logic       vblank,
    output logic       hsync,
    output logic       vsync,
    output logic       visible,    // this pixel is on screen
    output logic       line_start, // first ce_pix of a line
    output logic       frame_start // first ce_pix of the first visible line
);

    logic [2:0] div;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div <= '0; hcnt <= '0; vcnt <= '0;
        end else begin
            div <= div + 3'd1;
            if (div == 3'd7) begin
                if (hcnt == HTOTAL - 9'd1) begin
                    hcnt <= '0;
                    vcnt <= (vcnt == VTOTAL - 9'd1) ? 9'd0 : vcnt + 9'd1;
                end else begin
                    hcnt <= hcnt + 9'd1;
                end
            end
        end
    end

    assign phase       = div;
    assign ce_pix      = (div == 3'd7);
    assign row         = vcnt[7:0] - VBEND[7:0];   // the visible line
    assign hblank      = (hcnt >= HBSTART);
    assign vblank      = (vcnt >= VBSTART) || (vcnt < VBEND);
    assign hsync       = (hcnt >= HSSTART) && (hcnt < HSEND);
    assign vsync       = (vcnt >= VSSTART) && (vcnt < VSEND);
    assign visible     = !hblank && !vblank;
    assign line_start  = ce_pix && (hcnt == HTOTAL - 9'd1);
    assign frame_start = line_start && (vcnt == VBEND - 9'd1);

endmodule
