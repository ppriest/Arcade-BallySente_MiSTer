// SPDX-License-Identifier: GPL-3.0-or-later
//
// The SAC-I main board: the MC6809E, the address decode and registers, the
// interrupt tap, the video path, and the three RAMs they share.
//
// The sound board is rtl/sound/sente6vb.sv, joined to this one by the serial
// link below; the main program waits on it at boot (rtl/acia6850.sv).
//
// THE RAMs ARE DUAL-PORTED AND NOTHING IS ARBITRATED. The CPU writes them at
// 1.25 MHz while the video engine reads them at the pixel rate, which is what
// the board does -- it races the beam, and every set writes video RAM and
// sprite RAM during active display (docs/HARDWARE_NOTES.md, "Raster timing").
// A write landing on the pixel being fetched shows up on that pixel, exactly as
// on the board. There is no frame buffer and no copy.
//
//   0000-07ff  RAM      2 KB. The low 256 bytes are the sprite list the video
//                       engine walks; the rest is work RAM.
//   0800-7fff  video    30,720 bytes, the 256x240 4bpp bitmap
//   8000-8fff  palette  1024 entries of 4 bytes, held as four byte planes so
//                       the video side can read a whole entry in one cycle
//                       while the CPU still addresses it as bytes

module game_board #(
    // See rtl/main_bus.sv: 1 floats an undriven read as the board does, 0 is
    // MAME's 0x00. Passed through so a bench can compare against MAME.
    parameter bit OPEN_BUS = 1
) (
    input  logic        clk,           // clk_sys, 40 MHz
    input  logic        rst_n,
    input  logic        raster_rst_n,   // the raster counters only; see video.sv

    // Cartridge wiring, from the .mra
    input  logic [5:0]  cfg_cdmask,
    input  logic        cfg_swap,
    input  logic        cfg_banks16,
    input  logic [2:0]  cfg_variant,   // main_bus.sv; 5 is Night Stocker's gun

    // Program ROM, 128 or 256 KB
    output logic [17:0] prg_addr,
    input  logic [7:0]  prg_q,

    // Sprite ROM, 64 KB
    output logic [15:0] gfx_addr,
    input  logic [7:0]  gfx_q,

    // Inputs, active low as the CPU reads them
    input  logic [7:0]  in_swh,
    input  logic [7:0]  in_swg,
    input  logic [7:0]  in_in0,
    input  logic [7:0]  in_in1,

    // The serial link to the 6VB, which also supplies the ACIA's clock
    input  logic        uart_clk,
    input  logic        acia_rxd,
    output logic        acia_txd,

    // Suspends the CPU at the next bus-cycle boundary; video keeps running.
    input  logic        pause,
    input  logic        flip,           // the core's flip screen; see video.sv

    // The analog ports the ADC converts (rtl/analog_inputs.sv), and how the
    // game reads them (MAME's config_shooter_adc: a shift, or raw)
    input  logic [7:0]  an0, an1, an2, an3,
    input  logic [1:0]  adc_shift,
    input  logic        adc_raw,

    // teamht's input groups; Grudge Match's three wheel positions; Night
    // Stocker's gun position (MAME's FAKEX/FAKEY, 0x80 at the centre)
    input  logic [7:0]  ex0, ex1, ex2, ex3,
    input  logic [7:0]  wheel0, wheel1, wheel2,
    input  logic [7:0]  gun_x, gun_y,

    // The NOVRAMs from outside, for the save file: address bit 8 picks the
    // chip (0 system, 1 cartridge). nv_cpu_wr pulses on every CPU write.
    input  logic        nv_ext_we,
    input  logic [8:0]  nv_ext_addr,
    input  logic [3:0]  nv_ext_din,
    output logic [3:0]  nv_ext_q,
    output logic        nv_cpu_wr,

    output logic [3:0]  r,
    output logic [3:0]  g,
    output logic [3:0]  b,
    output logic        hsync,
    output logic        vsync,
    output logic        hblank,
    output logic        vblank,
    output logic        ce_pix,

    // For a bench or a probe
    output logic [15:0] cpu_addr,
    output logic        cpu_rnw,
    output logic        cen_E,
    output logic [8:0]  hpos,
    output logic [8:0]  vpos
);

    // ---------------------------------------------------------- clocking
    // E is clk_sys/32 = 1.25 MHz, Q a quarter period ahead, as
    // jtframe_6809wait phases them.
    // Pause is sampled on the last clock of a bus cycle, so a cycle is
    // either run whole or not at all: E and Q never come apart.
    logic [4:0] ephase;
    logic       cen_Q, run;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            ephase <= '0; run <= 1'b1;
        end else begin
            ephase <= ephase + 5'd1;
            if (ephase == 5'd31) run <= !pause;
        end
    assign cen_E = run && (ephase == 5'd0);
    assign cen_Q = run && (ephase == 5'd16);

    // --------------------------------------------------------------- CPU
    wire [2:0]  adc_sel;
    wire        adc_start;
    wire [7:0]  adc_q;
    wire        acia_sel;
    wire [7:0]  acia_q;
    wire        acia_irq_n;

    wire [15:0] ADDR;
    wire [7:0]  DOut;
    wire        RnW;
    logic [7:0] D;
    wire        irq;

    assign cpu_addr = ADDR;
    assign cpu_rnw  = RnW;

    mc6809i #(.ILLEGAL_INSTRUCTIONS("GHOST")) u_cpu (
        .D(D), .DOut(DOut), .ADDR(ADDR), .RnW(RnW),
        .clk(clk), .cen_E(cen_E), .cen_Q(cen_Q),
        .BS(), .BA(),
        .nIRQ(~irq), .nFIRQ(acia_irq_n), .nNMI(1'b1),
        .AVMA(), .BUSY(), .LIC(),
        .nHALT(1'b1), .nRESET(rst_n), .nDMABREQ(1'b1),
        .OP(), .RegData()
    );

    // ------------------------------------------------------------- board
    wire [7:0]  bus_q;
    wire        cs_ram, cs_vram, cs_pal, cs_rom;
    wire [1:0]  palbank;
    wire [7:0]  outlatch;
    wire        nvram_recall, nv0_sel, nv1_sel, nv_we, nv_8bit;
    wire [7:0]  nv_addr;

    // The NOVRAMs are two X2212s, 256 nibbles each, one array per chip so
    // rescraid can write both in a cycle (novram_8bit_w). The top level reads
    // and writes them through nv_ext_* for the .nvm file, bit 8 picking the chip.
    // A blank X2212 reads 0xF in every nibble (MAME x2212.cpp nvram_default).
    // Not a don't-care: cshift computes values from it on its first boot, and
    // starting at 0 changes what it writes back (sim/board_tb, write #6973).
    // SRAM and EEPROM are one array here and recall is not wired (docs/HACKS.md).
    logic [3:0] nva [0:255], nvb [0:255];
    initial for (int i = 0; i < 256; i++) begin nva[i] = 4'hf; nvb[i] = 4'hf; end
    wire [7:0]  nv_q = nv_8bit ? {nvb[nv_addr], nva[nv_addr]}
                     : nv0_sel ? {4'h0, nva[nv_addr]}
                     : nv1_sel ? {4'h0, nvb[nv_addr]} : 8'h00;
    assign nv_cpu_wr = nv_we;
    wire wa = nv_we && nv0_sel;
    wire wb = nv_we && (nv1_sel || (nv_8bit && nv0_sel));
    // The outside writes only while the CPU is held in reset (the .nvm load).
    always_ff @(posedge clk) begin
        if (nv_ext_we && !nv_ext_addr[8]) nva[nv_ext_addr[7:0]] <= nv_ext_din;
        else if (wa)                      nva[nv_addr] <= DOut[3:0];
    end
    always_ff @(posedge clk) begin
        if (nv_ext_we && nv_ext_addr[8])  nvb[nv_ext_addr[7:0]] <= nv_ext_din;
        else if (wb)                      nvb[nv_addr] <= nv_8bit ? DOut[7:4] : DOut[3:0];
    end
    assign nv_ext_q = nv_ext_addr[8] ? nvb[nv_ext_addr[7:0]] : nva[nv_ext_addr[7:0]];

    // ---------------------------------------------------------- variants
    wire        irq_tick;
    wire [8:0]  irq_line;
    wire [7:0]  steer_q;
    wire        steer_rd;
    grudge_steering u_steer (
        .clk(clk), .rst_n(rst_n), .tick(irq_tick), .rd(steer_rd),
        .wheel0(wheel0), .wheel1(wheel1), .wheel2(wheel2), .q(steer_q)
    );

    // interrupt_timer()'s shooter branch: the gun is latched at the line-64
    // interrupt, and each interrupt presents two bits of X and two of Y,
    // shifted one further each time. Line 0 (once, after reset) presents 0:
    // MAME shifts by -1 there.
    logic [7:0] sh_x, sh_y;
    logic [3:0] gun_bits;
    always_ff @(posedge clk or negedge rst_n) begin
        logic [7:0] tx, ty;
        if (!rst_n) begin
            sh_x <= 8'h80; sh_y <= 8'h80; gun_bits <= '0;
        end else if (irq_tick) begin
            if (irq_line == 9'd64) begin sh_x <= gun_x; sh_y <= gun_y; end
            tx = (irq_line == 9'd64) ? gun_x : sh_x;
            ty = (irq_line == 9'd64) ? gun_y : sh_y;
            case (irq_line)
                9'd64:   ;
                9'd128:  begin tx = tx << 1; ty = ty << 1; end
                9'd192:  begin tx = tx << 2; ty = ty << 2; end
                9'd256:  begin tx = tx << 3; ty = ty << 3; end
                default: begin tx = '0;      ty = '0;      end
            endcase
            // ((x >> 4) & 8) | ((x >> 1) & 4) | ((y >> 6) & 2) | ((y >> 3) & 1)
            gun_bits <= {tx[7], tx[3], ty[7], ty[3]};
        end
    end
    wire [7:0] in0_eff = (cfg_variant == 3'd5) ? {in_in0[7:4], gun_bits} : in_in0;

    main_bus #(.OPEN_BUS(OPEN_BUS)) u_bus (
        .clk(clk), .rst_n(rst_n), .cen_E(cen_E),
        .addr(ADDR), .rnw(RnW), .din(DOut), .cpu_d(D), .dout(bus_q),
        .cs_ram(cs_ram), .cs_vram(cs_vram), .cs_pal(cs_pal),
        .cfg_cdmask(cfg_cdmask), .cfg_swap(cfg_swap), .cfg_banks16(cfg_banks16),
        .cfg_variant(cfg_variant),
        .rom_addr(prg_addr), .rom_q(prg_q), .cs_rom(cs_rom),
        .palbank(palbank), .outlatch(outlatch), .nvram_recall(nvram_recall),
        .in_swh(in_swh), .in_swg(in_swg), .in_in0(in0_eff), .in_in1(in_in1),
        .vblank(vblank),
        .nv_addr(nv_addr), .nv0_sel(nv0_sel), .nv1_sel(nv1_sel),
        .nv_we(nv_we), .nv_q(nv_q), .nv_8bit(nv_8bit),
        .ex0(ex0), .ex1(ex1), .ex2(ex2), .ex3(ex3),
        .steer_q(steer_q), .steer_rd(steer_rd),
        .adc_sel(adc_sel), .adc_start(adc_start), .adc_q(adc_q),
        .acia_sel(acia_sel), .acia_we(), .acia_q(acia_q),
        .watchdog_kick()
    );

    adc u_adc (
        .clk(clk), .rst_n(rst_n), .start(adc_start), .sel(adc_sel),
        .an0(an0), .an1(an1), .an2(an2), .an3(an3),
        .shift(adc_shift), .raw(adc_raw), .q(adc_q)
    );

    // -------------------------------------------------------------- ACIA
    // Clocked by the 6VB's 500 kHz output, which is already the inverse of
    // that board's own ACIA clock (sente6vb.cpp uart_clock_w).
    acia6850 u_acia (
        .clk(clk), .rst_n(rst_n),
        .access(cen_E && acia_sel), .rnw(RnW), .rs(ADDR[0]),
        .din(DOut), .dout(acia_q),
        .txc(uart_clk), .rxc(uart_clk),
        .rxd(acia_rxd), .cts(1'b0), .dcd(1'b0),
        .txd(acia_txd), .rts(), .irq_n(acia_irq_n)
    );

    // ------------------------------------------------------------ memory
    wire cpu_wr = cen_E && !RnW;

    // Work and sprite RAM. Port B is the sprite engine, reading the low 256.
    logic [7:0] ram [0:2047];
    logic [7:0] ram_cpu_q, ram_spr_q;
    wire [7:0]  spr_addr;
    always_ff @(posedge clk) begin
        if (cpu_wr && cs_ram) ram[ADDR[10:0]] <= DOut;
        ram_cpu_q <= ram[ADDR[10:0]];
        ram_spr_q <= ram[{3'b0, spr_addr}];
    end

    // Video RAM. Port B is the scanout.
    logic [7:0] vram [0:30719];
    logic [7:0] vram_cpu_q, vram_vid_q;
    wire [14:0] vid_addr;
    always_ff @(posedge clk) begin
        if (cpu_wr && cs_vram) vram[ADDR - 16'h0800] <= DOut;
        vram_cpu_q <= vram[ADDR - 16'h0800];
        vram_vid_q <= vram[vid_addr];
    end

    // Palette, four byte planes so one read gives a whole entry. Each plane is
    // written and read on its own and the CPU's byte is chosen after the read:
    // a plane select inside the registered read is not a RAM Quartus
    // recognises, and it built all 32 Kbit from registers.
    logic [7:0] pal0 [0:1023], pal1 [0:1023], pal2 [0:1023], pal3 [0:1023];
    logic [7:0] pal_c0, pal_c1, pal_c2, pal_c3, pal_cpu_q;
    logic [1:0] pal_csel;
    logic [31:0] pal_vid_q;
    wire [9:0]  pal_vaddr;
    wire [9:0]  pal_caddr = ADDR[11:2];
    wire        pal_we    = cpu_wr && cs_pal;
    always_ff @(posedge clk) begin
        if (pal_we && ADDR[1:0] == 2'd0) pal0[pal_caddr] <= DOut;
        pal_c0 <= pal0[pal_caddr];
        pal_vid_q[7:0] <= pal0[pal_vaddr];
    end
    always_ff @(posedge clk) begin
        if (pal_we && ADDR[1:0] == 2'd1) pal1[pal_caddr] <= DOut;
        pal_c1 <= pal1[pal_caddr];
        pal_vid_q[15:8] <= pal1[pal_vaddr];
    end
    always_ff @(posedge clk) begin
        if (pal_we && ADDR[1:0] == 2'd2) pal2[pal_caddr] <= DOut;
        pal_c2 <= pal2[pal_caddr];
        pal_vid_q[23:16] <= pal2[pal_vaddr];
    end
    always_ff @(posedge clk) begin
        if (pal_we && ADDR[1:0] == 2'd3) pal3[pal_caddr] <= DOut;
        pal_c3 <= pal3[pal_caddr];
        pal_vid_q[31:24] <= pal3[pal_vaddr];
    end
    always_ff @(posedge clk) pal_csel <= ADDR[1:0];
    always_comb
        case (pal_csel)
            2'd0: pal_cpu_q = pal_c0;
            2'd1: pal_cpu_q = pal_c1;
            2'd2: pal_cpu_q = pal_c2;
            default: pal_cpu_q = pal_c3;
        endcase

    // The CPU's read multiplexer. The RAMs answer a cycle after the address,
    // which is comfortably inside a 32-cycle CPU period.
    always_comb begin
        if      (cs_ram)  D = ram_cpu_q;
        else if (cs_vram) D = vram_cpu_q;
        else if (cs_pal)  D = pal_cpu_q;
        else              D = bus_q;
    end

    // ------------------------------------------------------------- video
    wire [8:0] vid_h, vid_v;
    assign hpos = vid_h;
    assign vpos = vid_v;

    video #(.VBEND(9'd16), .VCNT_RST(9'd256)) u_video (
        .clk(clk), .rst_n(rst_n), .raster_rst_n(raster_rst_n), .flip(flip), .palbank(palbank),
        .vram_addr(vid_addr), .vram_q(vram_vid_q),
        .sram_addr(spr_addr), .sram_q(ram_spr_q),
        .rom_addr(gfx_addr), .rom_q(gfx_q),
        .pal_addr(pal_vaddr), .pal_q(pal_vid_q),
        .r(r), .g(g), .b(b),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .ce_pix(ce_pix), .hpos(vid_h), .vpos(vid_v)
    );

    // The interrupt tap reads the video engine's own counters. A second
    // instance would be a second thing to keep in step for no gain.
    irq_timer u_irq (
        .clk(clk), .rst_n(rst_n),
        .hcnt(vid_h), .vcnt(vid_v), .irq(irq),
        .tick(irq_tick), .tick_line(irq_line)
    );

endmodule
