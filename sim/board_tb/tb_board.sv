// SPDX-License-Identifier: GPL-3.0-or-later
//
// The whole machine, rtl/balsente_core.sv, running from its own ROMs with
// nothing replayed: the 6809 boots, draws into video RAM, writes the palette
// and moves the sprite list while the video engine scans it out, and the 6VB
// on the serial link runs its own program, because the main program waits for
// it at boot. The ROMs arrive through the download port, from the image the
// .mra describes (scripts/build_mra.py --image), so the load path, the
// cartridge configuration and the input map are the ones the core will use.
//
// WHAT IS COMPARED, and why it is RAM rather than pixels. A frame of pixels is
// a weak signal when something is wrong: it says the picture differs, not what
// the CPU got wrong. Video RAM, the palette and the sprite list are what the
// program produced, so a mismatch points at the program's inputs. The video
// path is already checked to the pixel against the beam model (sim/video_tb),
// so checking it again here would prove nothing new.
//
// Frame numbering follows MAME's: its screen starts at vblank, so the board's
// raster resets to line 256 and a frame ends when the counter wraps.
//
//   +image=<file>              the download image, one byte a line
//   +dips=<hex>                <switches> bytes, SWH first (default: the .mra's)
//   +wlog=<file>               the main board's output writes
//   +iolog=<file>              the 6VB's I/O accesses, as sim/calib_tb logs them
//   +acialog=<file>            the main CPU's writes to its 6850, as sndtrace.lua logs them
//   +rxlog=<file>              the sound CPU's reads of its 6850, status and data, likewise
//   +ramlog=<file> +ramfrom=<s> +ramto=<s>   the sound CPU's RAM writes in that window
//   +pclog=<file>              with +ramfrom/+ramto: the sound CPU's opcode fetches in it
//   +frame=<n>                 dump after this many frames
//   +coin=<n>                  insert a coin at frame n, press Start a second later
//   +out=<dir>                 where to write vram.bin, pal.bin, sram.bin
`timescale 1ns/1ps

module tb_board #(
    parameter bit OPEN_BUS = 1
);

    logic clk = 0;
    always #12.5 clk = ~clk;              // 40 MHz
    logic rst_n = 0;

    localparam int IMAGE = 32'h52020;
    logic [7:0] image [0:IMAGE-1];

    logic        dl_wr = 0;
    logic [18:0] dl_addr = '0;
    logic [7:0]  dl_data = '0;
    logic [31:0] dips;

    wire [3:0]  r, g, b;
    wire        hsync, vsync, hblank, vblank, ce_pix, cen_E, cpu_rnw, snd_unsupported;
    wire [15:0] cpu_addr;
    wire [8:0]  hpos, vpos;

    int target;
    string image_file, outdir;

    balsente_core #(.OPEN_BUS(OPEN_BUS)) dut (
        .clk(clk), .raster_rst_n(1'b1), .rst_n(rst_n),
        .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data),
        .nv_ext_we(1'b0), .nv_ext_addr(9'd0), .nv_ext_din(4'd0), .nv_ext_q(), .nv_cpu_wr(),
        .joystick_0(joy0), .joystick_1(32'd0), .dips(dips), .pause(1'b0), .flip(1'b0),
        .ps2_mouse(25'd0), .stick0(16'd0), .stick1(16'd0), .spinner0(9'd0), .spinner1(9'd0),
        .r(r), .g(g), .b(b),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .ce_pix(ce_pix),
        .audio_en(audio_en), .snd_unsupported(snd_unsupported), .audio(audio),
        .cpu_addr(cpu_addr), .cpu_rnw(cpu_rnw), .cen_E(cen_E),
        .hpos(hpos), .vpos(vpos)
    );

    // ------------------------------------------------------------- audio
    // +coin=<n>: Coin (joystick bit 9) for frames n..n+5, Start (bit 8) for
    // n+90..n+95, as scripts/mame/sndtrace.lua presses them. Once a second: audio_en, samples, non-zero ones, peak, voice writes, and
    // the audio unit's saturating parameter-overrun and late-tick counters.
    wire               audio_en;
    wire signed [15:0] audio;
    logic [31:0]       joy0 = '0;
    int                acialog = 0, rxlog = 0, ramlog = 0, pclog = 0;
    logic [15:0]       last_m1 = '0;
    logic              m1_prev = 1'b1;
    real               ram_from = 0, ram_to = 0;
    longint            acyc = 0;
    int                f_peak = 0, m_peak = 0, en_n = 0;
    int                coin_at = -1, a_nz = 0, a_peak = 0, a_frame = 0, a_n = 0, a_cv = 0;
    always_ff @(posedge clk) begin
        joy0[9] <= coin_at >= 0 && frame >= coin_at && frame < coin_at + 6;
        joy0[8] <= coin_at >= 0 && frame >= coin_at + 90 && frame < coin_at + 96;
        if (acialog != 0 && dut.running && cen_E && !cpu_rnw && cpu_addr[15:1] == 15'h4d02)
            $fwrite(acialog, "%.9f\t%04X\t%02X\n", real'(acyc) / 40.0e6, cpu_addr, dut.u_main.DOut);
        if (dut.u_snd.mem_rd_start && !dut.u_snd.m1_n) last_m1 <= dut.u_snd.addr;
        if (dut.u_snd.clken) m1_prev <= dut.u_snd.m1_n;
        if (pclog != 0 && dut.u_snd.clken && dut.u_snd.in_ar && !dut.u_snd.mreq_n
            && real'(acyc) / 40.0e6 >= ram_from && real'(acyc) / 40.0e6 <= ram_to)
            $fwrite(pclog, "%.9f\t  bus %04X rd_n %0d acia_q %02X hold %02X din %02X\n", real'(acyc) / 40.0e6,
                    dut.u_snd.addr, dut.u_snd.rd_n, dut.u_snd.acia_q, dut.u_snd.acia_hold, dut.u_snd.din);
        if (pclog != 0 && dut.u_snd.clken && !dut.u_snd.m1_n && m1_prev
            && real'(acyc) / 40.0e6 >= ram_from && real'(acyc) / 40.0e6 <= ram_to)
            $fwrite(pclog, "%.9f\t%04X\tnmi %0d\n", real'(acyc) / 40.0e6, dut.u_snd.addr, dut.u_snd.nmi);
        if (rxlog != 0 && dut.u_snd.mem_rd_start && dut.u_snd.in_ar)
            $fwrite(rxlog, "%.9f\t%s\t%02X\t%04X\n", real'(acyc) / 40.0e6,
                    dut.u_snd.addr[0] ? "D" : "S", dut.u_snd.acia_q, last_m1);
        if (ramlog != 0 && dut.u_snd.mem_wr_start && dut.u_snd.in_ram
            && real'(acyc) / 40.0e6 >= ram_from && real'(acyc) / 40.0e6 <= ram_to)
            $fwrite(ramlog, "%.9f\t%04X\t%02X\n", real'(acyc) / 40.0e6, dut.u_snd.addr, dut.u_snd.dout);
        if (dut.running) acyc <= acyc + 1;
        if (dut.u_snd.cv_valid) a_cv <= a_cv + 1;
        if (dut.u_snd.u_audio.f_done) begin
            if ($signed(dut.u_snd.u_audio.f_out) > f_peak) f_peak <= $signed(dut.u_snd.u_audio.f_out);
            if ($signed(dut.u_snd.u_audio.f_mix) > m_peak) m_peak <= $signed(dut.u_snd.u_audio.f_mix);
        end
        if (dut.u_snd.u_audio.sample_tick && dut.u_snd.u_audio.en_s) en_n <= en_n + 1;
        if (dut.u_snd.u_audio.sample_valid) begin
            a_n <= a_n + 1;
            if (audio != 0) a_nz <= a_nz + 1;
            if (audio > a_peak) a_peak <= audio;
            else if (-audio > a_peak) a_peak <= -audio;
        end
        if (frame != a_frame) begin
            a_frame <= frame;
            if (frame % 60 == 0) begin
                $display("  audio frame %0d: audio_en %0d, %0d samples, %0d non-zero, peak %0d, %0d voice writes, %0d overruns, %0d late",
                         frame, audio_en, a_n, a_nz, a_peak, a_cv,
                         dut.u_snd.u_audio.u_params.overrun, dut.u_snd.u_audio.late);
                $display("    filter in peak %0d, out peak %0d, ticks with en_s %0d, gf %h %h %h %h %h %h",
                         m_peak, f_peak, en_n,
                         dut.u_snd.u_audio.u_params.a_gf[0], dut.u_snd.u_audio.u_params.a_gf[1],
                         dut.u_snd.u_audio.u_params.a_gf[2], dut.u_snd.u_audio.u_params.a_gf[3],
                         dut.u_snd.u_audio.u_params.a_gf[4], dut.u_snd.u_audio.u_params.a_gf[5]);
                a_nz <= 0; a_peak <= 0; a_n <= 0; a_cv <= 0; f_peak <= 0; m_peak <= 0; en_n <= 0;
            end
        end
    end

    // ------------------------------------------------------------- frames
    int  frame = 0;
    logic [8:0] vprev;
    always_ff @(posedge clk) begin
        vprev <= vpos;
        if (dut.running && vpos == 9'd0 && vprev == 9'd263) frame <= frame + 1;
    end

    // A liveness check that does not depend on MAME: a board that never writes
    // video RAM has not booted, whatever the pixels look like.
    int vram_writes = 0, pal_writes = 0, sram_writes = 0;
    always_ff @(posedge clk) if (dut.running && cen_E && !cpu_rnw) begin
        if (cpu_addr >= 16'h0800 && cpu_addr <= 16'h7fff) vram_writes <= vram_writes + 1;
        else if (cpu_addr >= 16'h8000 && cpu_addr <= 16'h8fff) pal_writes <= pal_writes + 1;
        else if (cpu_addr <= 16'h00ff) sram_writes <= sram_writes + 1;
    end

    // Which registers the CPU READS, by 256-byte page of the I/O window. A
    // divergence that appears only after hundreds of frames is almost always a
    // peripheral the board answers differently, and this says which one to look
    // at instead of guessing.
    int io_rd [0:15];
    int rd_random = 0, rd_acia = 0, rd_acia_data = 0;
    always_ff @(posedge clk) if (dut.running && cen_E && cpu_rnw
                                 && cpu_addr >= 16'h9000 && cpu_addr <= 16'h9fff) begin
        io_rd[cpu_addr[11:8]] <= io_rd[cpu_addr[11:8]] + 1;
        if (cpu_addr >= 16'h9a00 && cpu_addr <= 16'h9a03) rd_random <= rd_random + 1;
        if (cpu_addr >= 16'h9a04 && cpu_addr <= 16'h9a05) rd_acia   <= rd_acia + 1;
        // The data register: in MAME cshift first reads it at frame 560, the
        // 6VB's answer once its calibration is done.
        if (cpu_addr == 16'h9a05 && rd_acia_data < 4) begin
            $display("  frame %0d: main CPU reads the ACIA data register, %02X",
                     frame, dut.u_main.acia_q);
            rd_acia_data <= rd_acia_data + 1;
        end
    end

    // Every write the program makes to what it OUTPUTS -- video RAM, palette,
    // sprite list, I/O -- one line each, with frame markers, for
    // scripts/diff_write_stream.py. Work RAM and the stack are left out: where
    // an interrupt lands in the main stream differs between mc6809i and MAME
    // (docs/MAME_KLUDGES.md), which reorders them without changing what the
    // program draws.
    int  wlog = 0;
    int  wframe = -1;
    always_ff @(posedge clk) if (wlog != 0 && dut.running && cen_E && !cpu_rnw
                                 && (cpu_addr >= 16'h0800 || cpu_addr <= 16'h00ff)) begin
        if (frame != wframe) begin
            $fwrite(wlog, "# frame %0d\n", frame);
            wframe <= frame;
        end
        $fwrite(wlog, "w\t%04X\t%02X\n", cpu_addr, dut.u_main.DOut);
    end

    // The 6VB's I/O, in MAME's trace format, one cycle after io_cs because
    // sente6vb_io latches its read data there (see sim/calib_tb).
    int  iolog = 0, io_n = 0;
    logic       io_cs_d, io_wr_d;
    logic [7:0] io_addr_d, io_din_d;
    always_ff @(posedge clk) begin
        io_cs_d   <= dut.u_snd.io_cs;
        io_wr_d   <= !dut.u_snd.wr_n;
        io_addr_d <= dut.u_snd.addr[7:0];
        io_din_d  <= dut.u_snd.dout;
        if (iolog != 0 && io_cs_d) begin
            io_n <= io_n + 1;
            $fwrite(iolog, "%0d\t%s\t%02X\tFF\t%02X\n", io_n + 1, io_wr_d ? "w" : "r",
                    io_addr_d, io_wr_d ? io_din_d : dut.u_snd.io_dout);
        end
    end

    task automatic dump(input string name, input int n, input int which);
        int f;
        f = $fopen({outdir, "/", name}, "wb");
        if (f == 0) $fatal(1, "cannot write %s/%s", outdir, name);
        for (int i = 0; i < n; i++) begin
            case (which)
                0: $fwrite(f, "%c", dut.u_main.vram[i]);
                1: $fwrite(f, "%c", (i[1:0] == 2'd0) ? dut.u_main.pal0[i >> 2] :
                                    (i[1:0] == 2'd1) ? dut.u_main.pal1[i >> 2] :
                                    (i[1:0] == 2'd2) ? dut.u_main.pal2[i >> 2] :
                                                       dut.u_main.pal3[i >> 2]);
                2: $fwrite(f, "%c", dut.u_main.ram[i]);
                default: ;
            endcase
        end
        $fclose(f);
    endtask

    initial begin
        string wl;
        if (!$value$plusargs("image=%s", image_file)) image_file = "debug/rom/cshift_image.hex";
        if (!$value$plusargs("out=%s", outdir))       outdir = "debug/cshift-board";
        if (!$value$plusargs("frame=%d", target))     target = 1200;
        void'($value$plusargs("coin=%d", coin_at));
        // cshift's .mra default; MAME ran its own defaults for the reference.
        if (!$value$plusargs("dips=%h", dips))        dips = 32'hffff7fff;

        foreach (image[i]) image[i] = 8'h00;
        $readmemh(image_file, image);
        if (image[IMAGE - 32 + 16] === 8'h00 && image[IMAGE - 32 + 17] === 8'h00)
            $fatal(1, "%s has no input map -- build it with scripts/build_mra.py --image",
                   image_file);

        if ($value$plusargs("wlog=%s", wl))  wlog  = $fopen(wl, "w");
        if ($value$plusargs("iolog=%s", wl)) iolog = $fopen(wl, "w");
        if ($value$plusargs("acialog=%s", wl)) acialog = $fopen(wl, "w");
        if ($value$plusargs("rxlog=%s", wl)) rxlog = $fopen(wl, "w");
        if ($value$plusargs("ramlog=%s", wl)) ramlog = $fopen(wl, "w");
        if ($value$plusargs("pclog=%s", wl)) pclog = $fopen(wl, "w");
        void'($value$plusargs("ramfrom=%f", ram_from));
        void'($value$plusargs("ramto=%f", ram_to));

        // The download, one byte every second clock, with the core in reset
        // as MiSTer holds it.
        repeat (10) @(posedge clk);
        for (int i = 0; i < IMAGE; i++) begin
            dl_addr <= 19'(i); dl_data <= image[i]; dl_wr <= 1'b1;
            @(posedge clk);
            dl_wr <= 1'b0;
            @(posedge clk);
        end
        repeat (300) @(posedge clk);
        rst_n = 1;

        wait (frame >= target);
        $display("board_tb: frame %0d reached", frame);
        $display("  CPU writes so far: %0d video RAM, %0d palette, %0d sprite list",
                 vram_writes, pal_writes, sram_writes);
        if (vram_writes == 0)
            $display("  FAIL the CPU never wrote video RAM -- it has not booted");
        dump("vram.bin", 30720, 0);
        dump("pal.bin",  4096,  1);
        dump("sram.bin", 256,   2);
        $display("  of the 9axx reads: %0d random, %0d ACIA", rd_random, rd_acia);
        for (int i = 0; i < 16; i++)
            if (io_rd[i] != 0)
                $display("  I/O reads at 9%1Xxx: %0d", i, io_rd[i]);
        if (snd_unsupported) $display("  NOTE the 6VB's 8253 saw a mode it does not implement");
        if (wlog != 0) $fclose(wlog);
        if (iolog != 0) $fclose(iolog);
        if (acialog != 0) $fclose(acialog);
        if (rxlog != 0) $fclose(rxlog);
        if (ramlog != 0) $fclose(ramlog);
        if (pclog != 0) $fclose(pclog);
        $display("  -> %s/{vram,pal,sram}.bin", outdir);
        $finish;
    end

endmodule
