// SPDX-License-Identifier: GPL-3.0-or-later
//
// Area and timing for the video path alone: the raster, the sprite engine with
// its line buffer, and the background/palette read chain.
//
// The four memories are driven from an LFSR rather than instantiated, the same
// way rtl/sound/synth_check does it. They belong to the memory map, not to this
// module -- video RAM and sprite RAM are the CPU's own RAM and the sprite ROM
// goes to SDRAM in Phase 2 -- so including them here would measure a decision
// that has not been made and hide the one thing this project owns: the logic,
// and the one block RAM the line buffer really is.
//
// Every output is XOR-reduced onto one pin so nothing can be optimised away.

module video_synth_top (
    input  logic clk,
    input  logic rst_n,
    input  logic stim,
    output logic result
);

    logic [31:0] pat;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) pat <= 32'h1234_5678;
        else        pat <= {pat[30:0], pat[31] ^ pat[21] ^ pat[1] ^ stim};

    logic [14:0] vram_addr;
    logic [7:0]  sram_addr;
    logic [15:0] rom_addr;
    logic [9:0]  pal_addr;
    logic [3:0]  r, g, b;
    logic        hsync, vsync, hblank, vblank, ce_pix;

    video #(.VBEND(9'd16)) dut (
        .clk(clk), .rst_n(rst_n), .raster_rst_n(rst_n), .flip(1'b0),
        .palbank(pat[1:0]),
        .vram_addr(vram_addr), .vram_q(pat[7:0]),
        .sram_addr(sram_addr), .sram_q(pat[15:8]),
        .rom_addr(rom_addr),   .rom_q(pat[23:16]),
        .pal_addr(pal_addr),   .pal_q(pat ^ 32'hA5A5_5A5A),
        .r(r), .g(g), .b(b),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .ce_pix(ce_pix)
    );

    always_ff @(posedge clk)
        result <= ^{r, g, b, hsync, vsync, hblank, vblank, ce_pix,
                    vram_addr, sram_addr, rom_addr, pal_addr};

endmodule
