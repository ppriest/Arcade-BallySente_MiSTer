// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/main_bus.sv answering the MC6809E for real, with no replay, diffed
// against MAME's bus trace.
//
// sim/cpu_boot_tb proved the CPU and the cartridge mapper by handing it a
// recording of what MAME's CPU was given at each I/O read. That is the right
// way to isolate a CPU and the wrong way to check a board: it verifies nothing
// about the peripherals. Here every read is answered by the RTL -- decode,
// banking, inputs, VBLANK, the NOVRAMs, the watchdog -- and the trace has to
// match anyway.
//
// `sentetst` is no use for this: over 400,000 accesses it touches the I/O space
// only to kick the watchdog, so a no-replay run would match trivially. `cshift`
// exercises 2,726 NOVRAM accesses, 305 input reads, both ROM bank writes and
// the output latch, which is a real surface.
//
//   +rom=<file>     debug/rom/<set>_maincpu.hex
//   +trace=<file>   debug/<set>-boot/<set>_rtl.trace
//   +maxacc=<n>     stop after n bus cycles
//   +cdmask=<h> +swap=<0|1> +banks16=<0|1>   the cartridge wiring
//
// FIRQ is still tied off: it comes from the main-board ACIA, and the sound
// board is Phase 3. IRQ is real -- rtl/irq_timer.sv -- and cshift takes its
// first one at cycle 79,363, so everything past that depends on it.
`timescale 1ns/1ps

module tb_mainbus;

    localparam real CLK_NS = 25.0;      // 40 MHz clk_sys
    localparam int  ECYC   = 32;        // E is clk_sys/32 = 1.25 MHz

    logic clk = 0;
    always #(CLK_NS / 2.0) clk = ~clk;

    logic [4:0] phase = 0;
    logic cen_E, cen_Q;
    always @(posedge clk) phase <= phase + 5'd1;
    assign cen_E = (phase == 5'd0);
    assign cen_Q = (phase == 5'd16);

    logic nRESET = 0;

    // ------------------------------------------------------------------ CPU
    wire [15:0] ADDR;
    wire [7:0]  DOut;
    wire        RnW, BS, BA, AVMA, BUSY, LIC, OP;
    logic [7:0] D;

    mc6809i #(.ILLEGAL_INSTRUCTIONS("GHOST")) u_cpu (
        .D(D), .DOut(DOut), .ADDR(ADDR), .RnW(RnW),
        .clk(clk), .cen_E(cen_E), .cen_Q(cen_Q),
        .BS(BS), .BA(BA),
        .nIRQ(~irq), .nFIRQ(1'b1), .nNMI(1'b1),
        .AVMA(AVMA), .BUSY(BUSY), .LIC(LIC),
        .nHALT(1'b1), .nRESET(nRESET), .nDMABREQ(1'b1),
        .OP(OP), .RegData()
    );

    // -------------------------------------------------------------- memory
    // The CPU sees RAM, video RAM and the palette as plain memory; in the core
    // they are dual-ported with the video engine, which is not wired here.
    logic [7:0] ram [0:16'h8fff];
    logic [7:0] prg [0:18'h3ffff];

    // --------------------------------------------------------- the raster
    // Only VBLANK matters here, but it has to be in MAME's phase: MAME starts
    // a screen at vblank start, so the counter resets there.
    logic vblank_r, irq;
    logic [8:0] hcnt_r, vcnt_r;
    video_timing #(.VCNT_RST(9'd256)) u_timing (
        .clk(clk), .rst_n(nRESET),
        .ce_pix(), .phase(), .hcnt(hcnt_r), .vcnt(vcnt_r), .row(),
        .hblank(), .vblank(vblank_r), .hsync(), .vsync(),
        .visible(), .line_start(), .frame_start()
    );

    // FIRQ comes from the main-board ACIA and is still tied off: the sound
    // board is Phase 3, so nothing can raise it here.
    irq_timer u_irq (
        .clk(clk), .rst_n(nRESET),
        .hcnt(hcnt_r), .vcnt(vcnt_r), .irq(irq)
    );

    // --------------------------------------------------------- the NOVRAMs
    // Two X2212s: 256 nibbles each, SRAM and EEPROM. A read returns the nibble
    // with the space's unmapped value in the top half, which is 0 on this
    // driver; both halves start at 0xf (x2212_device::device_start).
    logic [3:0] nv0_sram [0:255], nv0_ee [0:255];
    logic [3:0] nv1_sram [0:255], nv1_ee [0:255];

    wire [7:0] nv_addr;
    wire       nv0_sel, nv1_sel, nv_we, nvram_recall;
    wire [7:0] nv_q = nv0_sel ? {4'h0, nv0_sram[nv_addr]}
                  : nv1_sel ? {4'h0, nv1_sram[nv_addr]}
                            : 8'h00;

    logic recall_d;
    always_ff @(posedge clk) begin
        if (nv_we) begin
            if (nv0_sel) nv0_sram[nv_addr] <= DOut[3:0];
            if (nv1_sel) nv1_sram[nv_addr] <= DOut[3:0];
        end
        // nvrecall_w: the LS259's bit 7, active low. MAME recalls on the edge.
        recall_d <= nvram_recall;
        if (nvram_recall && !recall_d)
            for (int i = 0; i < 256; i++) begin
                nv0_sram[i] <= nv0_ee[i];
                nv1_sram[i] <= nv1_ee[i];
            end
    end

    // --------------------------------------------------------- the board
    int cdmask, swap, banks16, maxacc;
    string rom_file, trace_file;

    wire [7:0]  bus_q;
    wire        cs_ram, cs_vram, cs_pal, cs_rom;
    wire [17:0] rom_addr;
    wire [1:0]  palbank;
    wire [7:0]  outlatch;
    wire [2:0]  adc_sel;
    wire        adc_start, acia_sel, acia_we, watchdog_kick;

    // OPEN_BUS 0 puts the board in MAME's mode -- undriven reads and the top
    // half of a NOVRAM byte come back 0x00 -- because this bench exists to diff
    // against MAME's trace and an open bus differs from it on every NOVRAM
    // read. The core itself uses the default, which is the board's behaviour.
    main_bus #(.OPEN_BUS(0)) u_bus (
        .clk(clk), .rst_n(nRESET), .cen_E(cen_E),
        .addr(ADDR), .rnw(RnW), .din(DOut), .cpu_d(D), .dout(bus_q),
        .cs_ram(cs_ram), .cs_vram(cs_vram), .cs_pal(cs_pal),
        .cfg_cdmask(6'(cdmask)), .cfg_swap(1'(swap)), .cfg_banks16(1'(banks16)),
        .rom_addr(rom_addr), .rom_q(prg[rom_addr]), .cs_rom(cs_rom),
        .palbank(palbank), .outlatch(outlatch), .nvram_recall(nvram_recall),
        .in_swh(8'hff), .in_swg(8'hff), .in_in0(8'hff), .in_in1(8'hff),
        .vblank(vblank_r),
        .nv_addr(nv_addr), .nv0_sel(nv0_sel), .nv1_sel(nv1_sel),
        .nv_we(nv_we), .nv_q(nv_q),
        .adc_sel(adc_sel), .adc_start(adc_start), .adc_q(8'h00),
        .acia_sel(acia_sel), .acia_we(acia_we), .acia_q(8'h00),
        .watchdog_kick(watchdog_kick)
    );

    // RAM answers itself; everything else comes from the board.
    always_comb begin
        if (cs_ram || cs_vram || cs_pal) D = ram[ADDR];
        else                             D = bus_q;
    end

    // ------------------------------------------------------------- trace
    int fd, acc = 0, opfetch = 0;

    initial begin
        if (!$value$plusargs("rom=%s", rom_file))     rom_file = "debug/rom/cshift_maincpu.hex";
        if (!$value$plusargs("trace=%s", trace_file)) trace_file = "debug/cshift-boot/cshift_rtl.trace";
        if (!$value$plusargs("maxacc=%d", maxacc))    maxacc = 400000;
        if (!$value$plusargs("cdmask=%d", cdmask))    cdmask = 0;
        if (!$value$plusargs("swap=%d", swap))        swap = 0;
        if (!$value$plusargs("banks16=%d", banks16))  banks16 = 0;

        foreach (ram[i]) ram[i] = 8'h00;
        foreach (prg[i]) prg[i] = 8'h00;
        for (int i = 0; i < 256; i++) begin
            nv0_sram[i] = 4'hf; nv0_ee[i] = 4'hf;
            nv1_sram[i] = 4'hf; nv1_ee[i] = 4'hf;
        end
        $readmemh(rom_file, prg);
        if (prg[18'h1e000] === 8'h00 && prg[18'h1e001] === 8'h00)
            $display("WARNING  the ROM image looks empty -- check the path and the CWD");

        fd = $fopen(trace_file, "w");
        if (fd == 0) $fatal(1, "cannot write %s", trace_file);
        $fwrite(fd, "# RTL main-CPU bus accesses from reset, in order.\n");
        $fwrite(fd, "# seq\trw\taddr\tmask\tdata\n");

        repeat (8 * ECYC) @(posedge clk);
        nRESET <= 1;
    end

    // When each IRQ asserts, in CPU cycles, so a phase error against MAME is a
    // number rather than a guess.
    logic irq_d;
    int   n_irq = 0;
    always @(posedge clk) begin
        irq_d <= irq;
        if (nRESET && irq && !irq_d && n_irq < 6) begin
            n_irq <= n_irq + 1;
            $display("IRQ %0d asserts at CPU cycle %0d, vcnt %0d", n_irq, acc, vcnt_r);
        end
    end

    always @(posedge clk) begin
        if (nRESET && cen_E) begin
            acc <= acc + 1;
            if (OP) opfetch <= opfetch + 1;
            if (RnW) begin
                $fwrite(fd, "%0d\tr\t%04X\tFF\t%02X\n", acc + 1, ADDR, D);
            end else begin
                if (cs_ram || cs_vram || cs_pal) ram[ADDR] <= DOut;
                $fwrite(fd, "%0d\tw\t%04X\tFF\t%02X\n", acc + 1, ADDR, DOut);
            end

            if (acc + 1 >= maxacc) begin
                $fwrite(fd, "# %0d accesses logged\n", acc + 1);
                $fclose(fd);
                $display("RTLTRACE %0d accesses -> %s", acc + 1, trace_file);
                $display("         %0d opcode fetches, palette bank %0d, latch %02X",
                         opfetch, palbank, outlatch);
                $finish;
            end
        end
    end

endmodule
