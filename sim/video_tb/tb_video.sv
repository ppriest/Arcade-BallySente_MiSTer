// SPDX-License-Identifier: GPL-3.0-or-later
//
// The video path against the beam-accurate model, one whole frame.
//
// MAME cannot be the pixel reference for this core: it renders a frame at
// vblank start from the RAM as it stands then, while the board draws line 100
// from the RAM as it stood at line 100 (docs/HARDWARE_NOTES.md, "Raster
// timing"). So the reference is `render_model.py`'s beam mode, fed from a
// capture taken with `mame_capture.py --beam`:
//
//   vram.hex sram.hex pal.hex   the RAM at the frame's first line
//   gfx.hex                     the sprite ROM
//   writes.txt                  every write, `beam_pos region offset data`
//   palbank.txt                 the palette bank per visible line
//   expected.bin                the frame the model says this should produce
//
//   +cap=<dir>   the capture directory, default debug/rescraid-beam
//
// The bench mirrors the DUT's raster counters rather than reaching into it: the
// counters are deterministic from reset, so `beam_pos` is line * 320 + pixel
// and a write is applied when the mirror reaches it. One frame is run to fill
// the pipeline -- the sprite engine builds each line during the one before --
// and the writes are applied during the second, which is the frame compared.
`timescale 1ns/1ps

module tb_video;

    localparam int HTOTAL = 320;
    localparam int VTOTAL = 264;
    localparam int VBEND  = 16;
    localparam int WIDTH  = 256;
    localparam int HEIGHT = 240;

    logic clk = 0;
    always #12.5 clk = ~clk;              // 40 MHz
    logic rst_n = 0;

    // ------------------------------------------------------------ memories
    logic [7:0]  vram [0:30719];
    logic [7:0]  sram [0:255];
    logic [7:0]  pal  [0:4095];
    logic [7:0]  gfx  [0:65535];

    logic [14:0] vram_addr;
    logic [7:0]  sram_addr;
    logic [15:0] rom_addr;
    logic [9:0]  pal_addr;
    logic [7:0]  vram_q, sram_q, rom_q;
    logic [31:0] pal_q;

    // Registered reads, as a block RAM gives: q is valid the cycle after addr.
    always_ff @(posedge clk) begin
        vram_q <= vram[vram_addr];
        sram_q <= sram[sram_addr];
        rom_q  <= gfx[rom_addr];
        // one 32-bit entry a read; big endian on the 6809 bus, so byte 0 is R
        pal_q  <= {pal[{pal_addr, 2'd3}], pal[{pal_addr, 2'd2}],
                   pal[{pal_addr, 2'd1}], pal[{pal_addr, 2'd0}]};
    end

    logic [1:0] palbank;
    logic [3:0] r, g, b;
    logic       hsync, vsync, hblank, vblank, ce_pix;

    video #(.VBEND(VBEND)) dut (
        .clk(clk), .rst_n(rst_n), .palbank(palbank),
        .vram_addr(vram_addr), .vram_q(vram_q),
        .sram_addr(sram_addr), .sram_q(sram_q),
        .rom_addr(rom_addr), .rom_q(rom_q),
        .pal_addr(pal_addr), .pal_q(pal_q),
        .r(r), .g(g), .b(b),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .ce_pix(ce_pix)
    );

    // -------------------------------------------- the mirrored raster
    int mh = 0, mv = 0;                   // the pixel the DUT is OUTPUTTING
    int phase = 0;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mh <= 0; mv <= 0; phase <= 0;
        end else begin
            phase <= (phase == 7) ? 0 : phase + 1;
            if (phase == 7) begin
                if (mh == HTOTAL - 1) begin
                    mh <= 0;
                    mv <= (mv == VTOTAL - 1) ? 0 : mv + 1;
                end else begin
                    mh <= mh + 1;
                end
            end
        end
    end

    // ---------------------------------------------------------- the writes
    localparam int MAXW = 65536;
    int    w_pos [0:MAXW-1];
    int    w_reg [0:MAXW-1];
    int    w_off [0:MAXW-1];
    int    w_dat [0:MAXW-1];
    int    n_w = 0, i_w = 0;

    int    bank_of [0:HEIGHT-1];

    // -------------------------------------------------------- the captures
    logic [7:0] frame [0:WIDTH*HEIGHT*3-1];
    int         n_pix = 0;
    bit         measuring = 0;

    string cap, cap_line;
    int    fd, code, a0, a1, a2, a3;

    initial begin
        if (!$value$plusargs("cap=%s", cap)) cap = "debug/rescraid-beam";

        $readmemh({cap, "/vram.hex"}, vram);
        $readmemh({cap, "/sram.hex"}, sram);
        $readmemh({cap, "/pal.hex"},  pal);
        $readmemh({cap, "/gfx.hex"},  gfx);

        fd = $fopen({cap, "/writes.txt"}, "r");
        if (fd == 0) $fatal(1, "cannot open %s/writes.txt -- run render_model.py --emit", cap);
        while (!$feof(fd)) begin
            code = $fscanf(fd, "%d %d %d %d\n", a0, a1, a2, a3);
            if (code != 4) begin
                void'($fgets(cap_line, fd));
                continue;
            end
            if (n_w < MAXW) begin
                w_pos[n_w] = a0; w_reg[n_w] = a1;
                w_off[n_w] = a2; w_dat[n_w] = a3;
                n_w++;
            end
        end
        $fclose(fd);

        fd = $fopen({cap, "/palbank.txt"}, "r");
        if (fd == 0) $fatal(1, "cannot open %s/palbank.txt", cap);
        for (int i = 0; i < HEIGHT; i++) void'($fscanf(fd, "%d\n", bank_of[i]));
        $fclose(fd);

        $display("video_tb: %s, %0d writes", cap, n_w);

        repeat (8) @(posedge clk);
        rst_n = 1;

        // One frame to fill the pipeline, then the frame that is measured.
        wait (mv == VTOTAL - 1 && mh == HTOTAL - 1);
        @(posedge clk);
        wait (mv == 0 && mh == 0);
        measuring = 1;

        wait (measuring == 0);

        begin
            int fo;
            fo = $fopen({cap, "/rtl_frame.bin"}, "wb");
            for (int i = 0; i < WIDTH*HEIGHT*3; i++) $fwrite(fo, "%c", frame[i]);
            $fclose(fo);
        end
        $display("video_tb: %0d pixels captured -> %s/rtl_frame.bin", n_pix, cap);
        $finish;
    end


    // The palette bank the DUT sees. It follows the line being FETCHED, not the
    // one being displayed: the core looks the palette up one pixel ahead, so
    // pixel 0 of a line is coloured during the last pixel of the previous one.
    // Indexing this by the displayed line gave pixel (0,0) of every frame the
    // previous line's bank -- one wrong pixel a frame, and the only failure in
    // the first run of this bench.
    int fetch_line;
    always_comb begin
        fetch_line = (mh == HTOTAL - 1) ? mv + 1 : mv;
        palbank = 2'd0;
        if (fetch_line >= VBEND && fetch_line < VBEND + HEIGHT)
            palbank = 2'(bank_of[fetch_line - VBEND]);
    end

    // Apply writes when the mirrored beam reaches them, during the measured
    // frame only.
    always_ff @(posedge clk) begin
        if (measuring && phase == 0) begin
            while (i_w < n_w && w_pos[i_w] <= mv * HTOTAL + mh) begin
                case (w_reg[i_w])
                    0: vram[w_off[i_w]] <= 8'(w_dat[i_w]);
                    1: sram[w_off[i_w]] <= 8'(w_dat[i_w]);
                    2: pal [w_off[i_w]] <= 8'(w_dat[i_w]);
                    default: ;
                endcase
                i_w++;
            end
        end
    end

    // Capture the visible pixels of the measured frame.
    always_ff @(posedge clk) begin
        if (measuring && phase == 0 && mh < WIDTH && mv >= VBEND && mv < VBEND + HEIGHT) begin
            automatic int o = ((mv - VBEND) * WIDTH + mh) * 3;
            frame[o]     <= {r, r};
            frame[o + 1] <= {g, g};
            frame[o + 2] <= {b, b};
            n_pix++;
        end
        if (measuring && mv == VBEND + HEIGHT && mh == 0 && phase == 0)
            measuring <= 0;
    end

endmodule
