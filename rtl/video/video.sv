// SPDX-License-Identifier: GPL-3.0-or-later
//
// The video path: raster, background scanout, sprite overlay, palette.
//
// The board races the beam and so does this (docs/HARDWARE_NOTES.md, "Raster
// timing"). Nothing is buffered a frame ahead: the background byte for a pixel
// is read as that pixel is drawn, the palette entry is read as it is needed,
// and the only buffer is the sprite engine's one line.
//
// HOW A PIXEL IS COLOURED. The background is a 256x240 4bpp packed bitmap, two
// pixels a byte, high nibble left. The sprite engine supplies a 4-bit nibble
// for the same pixel, 0 meaning transparent. The palette index is the two
// concatenated -- SPRITE HIGH, BACKGROUND LOW -- inside the current 256-entry
// bank, so a sprite recolours what is under it rather than replacing it. With
// no sprite the index is just the background nibble, which is the same thing
// with a zero high nibble.
//
// TIMING. Each pixel is eight clk_sys cycles (40 MHz / 5 MHz). Addresses for
// pixel P+1 are issued while P is on screen, so every read has its two cycles
// of block-RAM latency and the output needs no wait state:
//
//   phase 0   issue the background byte and the sprite nibble for P+1
//   phase 2   both answer; form the palette index for P+1
//   phase 3   issue the palette entry for P+1
//   phase 5   it answers; latch the colour for P+1
//   phase 7   the latched colour becomes the output as P+1 begins
//
// The palette is read 32 bits at a time, one entry a read: four bytes, big
// endian on this board's 6809 bus, R in byte 0, G in byte 1, B in byte 2 and
// byte 3 unused. Reading it as bytes would need three reads a pixel.
//
// FLIP SCREEN. The board has none; this is the core's, for the OSD and the
// .mra's fake DIP. Displayed pixel (x, row) shows stored pixel (255 - x,
// 239 - row): video RAM and the sprite line buffer are read mirrored, and the
// sprite engine draws the mirrored line. The palette bank is the one part the
// program changes by beam time, so the bank each row was drawn with is
// recorded and replayed mirrored; rows the beam has not reached yet this frame
// take last frame's (docs/HACKS.md). Taken at the start of a frame, so a
// change never tears one.

module video #(
    parameter logic [8:0] VBEND = 9'd16,
    // Where the vertical counter sits at reset. 0 is the natural one and is
    // what sim/video_tb mirrors; the board passes 256 so its raster is in the
    // same phase as MAME's screen, which starts at vblank.
    parameter logic [8:0] VCNT_RST = 9'd0
) (
    input  logic        clk,          // clk_sys, 40 MHz
    input  logic        rst_n,
    // The raster counters alone. Kept running while the rest is in reset, so
    // the display never loses sync (see rtl/balsente_core.sv).
    input  logic        raster_rst_n,

    // The palette bank, sampled per line: palette_select_w changes it mid-frame
    // (docs/MAME_KLUDGES.md).
    input  logic [1:0]  palbank,

    input  logic        flip,

    // Video RAM, byte wide, 0x0800-0x7fff as 0..30719. Registered read.
    output logic [14:0] vram_addr,
    input  logic [7:0]  vram_q,

    // Sprite RAM, the low 256 bytes. Registered read.
    output logic [7:0]  sram_addr,
    input  logic [7:0]  sram_q,

    // Sprite ROM. Registered read.
    output logic [15:0] rom_addr,
    input  logic [7:0]  rom_q,

    // Palette, one 32-bit entry a read. Registered.
    output logic [9:0]  pal_addr,
    input  logic [31:0] pal_q,

    output logic [3:0]  r,
    output logic [3:0]  g,
    output logic [3:0]  b,
    output logic        hsync,
    output logic        vsync,
    output logic        hblank,
    output logic        vblank,
    output logic        ce_pix,

    // The raster position, for whatever else needs it. The interrupt tap does,
    // and a second counter of its own would be a second thing to keep in step.
    output logic [8:0]  hpos,
    output logic [8:0]  vpos
);

    logic [2:0] phase;
    logic [8:0] hcnt, vcnt;
    assign hpos = hcnt;
    assign vpos = vcnt;
    logic [7:0] row;
    logic       visible, line_start, frame_start;

    video_timing #(.VBEND(VBEND), .VCNT_RST(VCNT_RST)) u_timing (
        .clk(clk), .rst_n(raster_rst_n),
        .ce_pix(ce_pix), .phase(phase), .hcnt(hcnt), .vcnt(vcnt), .row(row),
        // hpos/vpos are the same counters, published
        .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
        .visible(visible), .line_start(line_start), .frame_start(frame_start)
    );

    // The pixel being fetched for, one ahead of the one on screen -- and at the
    // last pixel of a line that is pixel 0 of the NEXT line, which is why the
    // row and the line follow it rather than following hcnt.
    wire       last_pix = (hcnt == 9'd319);
    wire [8:0] nx       = last_pix ? 9'd0 : hcnt + 9'd1;
    wire [8:0] nvcnt    = last_pix ? vcnt + 9'd1 : vcnt;
    wire [7:0] nrow     = nvcnt[7:0] - VBEND[7:0];
    wire       nvis     = (nx < 9'd256) && (nvcnt >= VBEND) && (nvcnt < 9'd256);

    logic      flip_f;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)           flip_f <= 1'b0;
        else if (frame_start) flip_f <= flip;

    // The stored pixel the fetched one shows.
    wire [7:0] crow     = flip_f ? 8'd239 - nrow : nrow;
    wire [7:0] cx       = flip_f ? 8'd255 - nx[7:0] : nx[7:0];

    // MAME's palette_select_w() redraws up to vpos() - 1 + VBEND before a bank
    // change, and vpos() is already absolute, so a write during raster line v
    // shows from line v + 16 on, a whole line at a time (docs/MAME_KLUDGES.md).
    // The bank is sampled at each line start; the line being fetched takes the
    // sample taken 15 line starts before its own (bank_hist[14] as it is
    // shifted), latched a pixel before its fetch begins, since pixel 0 is looked
    // up before hcnt reaches 319: a write in line v reaches v + 16.
    logic [1:0] bank_hist [0:14];
    logic [1:0] bank_line;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 15; i++) bank_hist[i] <= '0;
            bank_line <= '0;
        end else begin
            if (line_start) begin
                bank_hist[0] <= palbank;
                for (int i = 1; i < 15; i++) bank_hist[i] <= bank_hist[i - 1];
            end
            if (ce_pix && hcnt == 9'd318) bank_line <= bank_hist[14];
        end
    end

    // The bank each row was drawn with, for flip screen's mirrored replay.
    logic [1:0] bank_row [0:255];
    wire  [1:0] bank     = flip_f ? bank_row[crow] : bank_line;

    // ------------------------------------------------------------- sprites
    // Filled during this line for the next one.
    logic [3:0] spr_nib;
    logic       spr_busy;

    sprite_engine #(.VBEND(VBEND)) u_spr (
        .clk(clk), .rst_n(rst_n),
        .line_start(line_start),
        // Flipped, displayed line L shows stored line 2*VBEND + 239 - L.
        .build_line(flip_f ? {VBEND[7:0], 1'b0} + 9'd238 - nvcnt : nvcnt + 9'd1),
        .build_sel(~nvcnt[0]),
        .sram_addr(sram_addr), .sram_q(sram_q),
        .rom_addr(rom_addr), .rom_q(rom_q),
        .disp_sel(nvcnt[0]), .disp_x(cx), .disp_nibble(spr_nib),
        .busy(spr_busy)
    );

    // ---------------------------------------------------------- background
    logic [3:0] nr, ng, nb;
    logic       vis_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vram_addr <= '0; pal_addr <= '0; vis_n <= 1'b0;
            nr <= '0; ng <= '0; nb <= '0;
            r <= '0; g <= '0; b <= '0;
        end else begin
            case (phase)
                3'd0: begin
                    // two pixels a byte: 128 bytes a row
                    vram_addr <= {crow, 7'b0} + 15'(cx[7:1]);
                    vis_n     <= nvis;
                end
                3'd3: begin
                    // sprite nibble high, background low, inside the bank
                    pal_addr <= {bank, spr_nib, cx[0] ? vram_q[3:0] : vram_q[7:4]};
                    if (nx == 9'd0 && vis_n) bank_row[nrow] <= bank_line;
                end
                3'd5: begin
                    nr <= pal_q[3:0];        // byte 0
                    ng <= pal_q[11:8];       // byte 1
                    nb <= pal_q[19:16];      // byte 2
                end
                3'd7: begin
                    // blanking is black, so the scaler sees a clean border.
                    // vis_n belongs to the pixel just fetched, not to hcnt.
                    r <= vis_n ? nr : 4'd0;
                    g <= vis_n ? ng : 4'd0;
                    b <= vis_n ? nb : 4'd0;
                end
                default: ;
            endcase
        end
    end

endmodule
