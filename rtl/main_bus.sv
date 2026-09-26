// SPDX-License-Identifier: GPL-3.0-or-later
//
// The main board as the MC6809E sees it: address decode, the cartridge ROM
// window mapper, and every register at 0x9000-0x9fff.
//
// From balsente.cpp `cpu1_base_map` and balsente_m.cpp. The map is in
// docs/HARDWARE_NOTES.md, "Main CPU memory map"; what is here is the behaviour
// behind it.
//
//   0000-07ff  RAM        0000-00ff is the sprite list the video engine scans
//   0800-7fff  video RAM  the 256x240 4bpp bitmap the CPU draws into
//   8000-8fff  palette    1024 entries of 4 bytes
//   9000-9007  w  ADC start, input 0-7        9400   r  ADC data
//   9800-981f  w  LS259 output latch          9880   w  random reset
//   98a0       w  ROM bank                    98c0   w  palette bank
//   98e0       w  watchdog                    9900-03 r inputs and DIPs
//   9a00-9a03  r  random number               9a04-05 rw ACIA to the 6VB
//   9b00-9bff  rw system NOVRAM               9c00-9cff rw cartridge NOVRAM
//   9f00       w  second ROM bank (st1002)
//   a000-ffff  banked cartridge ROM
//
// RAM, video RAM and the palette are NOT here: they are dual-ported and shared
// with the video engine, so the top level owns them and this module only says
// when they are selected. The board races the beam and the CPU writes them
// while it does (docs/HARDWARE_NOTES.md, "Raster timing").

module main_bus #(
    // What an address with nothing driving it reads back.
    //
    // 1 (the default) is the BOARD: the data bus floats and the 6809 sees
    // whatever was last driven on it. That is what the hardware does, and it
    // applies to more than the gaps -- the X2212 NOVRAMs are 4-bit parts, so
    // the top half of every NOVRAM read floats too.
    //
    // 0 is MAME, which returns its unmapped value of 0x00 for both. Kept as a
    // parameter rather than deleted because the bus-trace diff against MAME is
    // the only verification this board has, and an open bus diverges from it on
    // every NOVRAM read. sim/mainbus_tb sets 0 to keep that lever; the core
    // uses the default.
    parameter bit OPEN_BUS = 1
) (
    input  logic        clk,           // clk_sys, 40 MHz
    input  logic        rst_n,
    input  logic        cen_E,         // 1.25 MHz CPU cycle

    // CPU bus
    input  logic [15:0] addr,
    input  logic        rnw,
    input  logic [7:0]  din,           // from the CPU
    input  logic [7:0]  cpu_d,         // the data bus as the CPU sees it
    output logic [7:0]  dout,          // to the CPU
    output logic        cs_ram,        // 0000-07ff
    output logic        cs_vram,       // 0800-7fff
    output logic        cs_pal,        // 8000-8fff

    // Cartridge configuration, from the .mra
    input  logic [5:0]  cfg_cdmask,    // expand_roms() low 6 bits
    input  logic        cfg_swap,      // SWAP_HALVES
    input  logic        cfg_banks16,   // a 256 KB maincpu region

    output logic [17:0] rom_addr,      // into the program ROM region
    input  logic [7:0]  rom_q,
    output logic        cs_rom,        // a000-ffff

    // Board state the rest of the core needs
    output logic [1:0]  palbank,
    output logic [7:0]  outlatch,      // LS259 U9H; bit 7 is NOVRAM recall
    output logic        nvram_recall,

    // Inputs. Active low as the board reads them, so the caller inverts
    // nothing: what arrives here is what the CPU sees.
    input  logic [7:0]  in_swh,        // 9900
    input  logic [7:0]  in_swg,        // 9901
    input  logic [7:0]  in_in0,        // 9902
    input  logic [7:0]  in_in1,        // 9903, bit 7 replaced by vblank
    input  logic        vblank,

    // NOVRAM, two X2212s, 256 nibbles each. Byte wide here; the top level
    // decides where they live and how they reach the SD card.
    output logic [7:0]  nv_addr,
    output logic        nv0_sel,
    output logic        nv1_sel,
    output logic        nv_we,
    input  logic [7:0]  nv_q,

    // ADC. The top level presents the selected channel.
    output logic [2:0]  adc_sel,
    output logic        adc_start,
    input  logic [7:0]  adc_q,

    // ACIA to the 6VB sound board. Phase 2 runs silent, so the top level may
    // tie acia_q to a value that keeps the main program happy.
    output logic        acia_sel,
    output logic        acia_we,
    input  logic [7:0]  acia_q,

    output logic        watchdog_kick
);

    // ------------------------------------------------------------- decode
    wire in_ram  = (addr <= 16'h07ff);
    wire in_vram = (addr >= 16'h0800) && (addr <= 16'h7fff);
    wire in_pal  = (addr >= 16'h8000) && (addr <= 16'h8fff);
    wire in_rom  = (addr >= 16'ha000);
    wire in_io   = (addr >= 16'h9000) && (addr <= 16'h9fff);

    assign cs_ram  = in_ram;
    assign cs_vram = in_vram;
    assign cs_pal  = in_pal;
    assign cs_rom  = in_rom;

    wire wr = cen_E && !rnw;

    // 9800-981f mirrors to 0x0060, 9880-989f, 98a0-98bf, 98c0-98df, 98e0-98ff
    wire sel_adc_w  = in_io && (addr[11:3]  == 9'b000_0000_00);          // 9000-9007
    wire sel_adc_r  = in_io && (addr[11:0]  == 12'h400);                 // 9400
    wire sel_latch  = in_io && (addr[11:8]  == 4'h8) && (addr[7:5] == 3'b000);
    wire sel_rndrst = in_io && (addr[11:5]  == 7'b1000_100);             // 9880-989f
    wire sel_bank   = in_io && (addr[11:5]  == 7'b1000_101);             // 98a0-98bf
    wire sel_palbk  = in_io && (addr[11:5]  == 7'b1000_110);             // 98c0-98df
    wire sel_wdog   = in_io && (addr[11:5]  == 7'b1000_111);             // 98e0-98ff
    wire sel_inp    = in_io && (addr[11:2]  == 10'b1001_0000_00);        // 9900-9903
    wire sel_rnd    = in_io && (addr[11:2]  == 10'b1010_0000_00);        // 9a00-9a03
    wire sel_acia   = in_io && (addr[11:1]  == 11'b1010_0000_010);       // 9a04-9a05
    wire sel_nv0    = in_io && (addr[11:8]  == 4'hb);                    // 9b00-9bff
    wire sel_nv1    = in_io && (addr[11:8]  == 4'hc);                    // 9c00-9cff
    wire sel_bank2  = in_io && (addr[11:0]  == 12'hf00);                 // 9f00

    assign watchdog_kick = wr && sel_wdog;
    assign nv_addr  = addr[7:0];
    assign nv0_sel  = sel_nv0;
    assign nv1_sel  = sel_nv1;
    assign nv_we    = wr && (sel_nv0 || sel_nv1);
    assign adc_sel  = addr[2:0];
    assign adc_start = wr && sel_adc_w;
    assign acia_sel = sel_acia;
    assign acia_we  = wr && sel_acia;

    // ------------------------------------------------------------ registers
    logic [3:0] bank_ab;
    logic [3:0] bank_cd;
    logic       bank_ef;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bank_ab <= '0; bank_cd <= '0; bank_ef <= 1'b0;
            palbank <= '0; outlatch <= '0;
        end else if (wr) begin
            // rombank_select_w: bits 6:4, and both windows follow it
            if (sel_bank) begin
                bank_ab <= {1'b0, din[6:4]};
                bank_cd <= {1'b0, din[6:4]};
                bank_ef <= 1'b0;
            end
            // rombank2_select_w, st1002 cartridges. Bit 5 says the write is for
            // the AB window, and setting AB resets CD to bank 6; otherwise both
            // windows take the bank. Bit 7 picks the upper half on a 256 KB
            // region (Name That Tune).
            if (sel_bank2) begin
                logic [3:0] b;
                b = {cfg_banks16 ? din[7] : 1'b0, din[2:0]};
                if (din[5]) begin
                    bank_ab <= b;
                    bank_cd <= 4'd6;
                    bank_ef <= 1'b0;
                end else begin
                    bank_ab <= b;
                    bank_cd <= b;
                    bank_ef <= 1'b0;
                end
            end
            if (sel_palbk) palbank <= din[1:0];
            // LS259: one bit at a time, addressed by bits 4:2, data is D7
            if (sel_latch) outlatch[addr[4:2]] <= din[7];
        end
    end

    assign nvram_recall = !outlatch[7];

    // ------------------------------------------------- cartridge mapping
    // balsente.cpp expand_roms(): bank pointers, not a ROM transform. Each
    // window is a base plus 0x2000 per bank, with SWAP_HALVES XORing 0x2000
    // into every one of them. Banks 6 and 7, and any bank whose mask bit is
    // clear, take the common CD ROM at 0x1c000.
    wire [17:0] swapx = cfg_swap ? 18'h02000 : 18'h00000;
    wire [17:0] grp_ab = bank_ab[3] ? 18'h20000 : 18'h00000;
    wire [17:0] grp_cd = bank_cd[3] ? 18'h20000 : 18'h00000;

    wire [2:0]  nab = bank_ab[2:0];
    wire [2:0]  ncd = bank_cd[2:0];
    wire        cd_common = (ncd >= 3'd6) || !cfg_cdmask[ncd];

    always_comb begin
        rom_addr = 18'd0;
        if (addr <= 16'hbfff)
            rom_addr = grp_ab + ((18'(nab) << 13) ^ swapx) + 18'(addr - 16'ha000);
        else if (addr <= 16'hdfff)
            rom_addr = grp_cd
                     + (cd_common ? (18'h1c000 ^ swapx)
                                  : (18'h10000 + ((18'(ncd) << 13) ^ swapx)))
                     + 18'(addr - 16'hc000);
        else
            rom_addr = (bank_ef ? 18'h20000 : 18'h00000) + (18'h1e000 ^ swapx)
                     + 18'(addr - 16'he000);
    end

    // -------------------------------------------------- hardware random
    // balsente_m.cpp poly17_init() and random_num_r(). A 17-bit recurrence,
    // x = ((x << 7) + (x >> 10) + 0x18000) & 0x1ffff, read as bits 10:3.
    //
    // MAME indexes it by `total_cycles * 12.5` -- 12 steps on an even CPU cycle
    // and 13 on an odd one -- because it computes (cc<<3)+(cc<<2)+(cc>>1).
    // Note the direction: the comment says the CPU is 1.25 MHz and the noise
    // source 100 kHz, which would DIVIDE by 12.5. Multiplying runs the sequence
    // 156 times faster than the board's noise source could. Reproduced anyway,
    // because MAME is the reference and a different value desynchronises a bus
    // trace immediately; docs/MAME_KLUDGES.md has the entry.
    logic [16:0] poly;
    logic [3:0]  steps;
    logic        cyc_odd;
    wire [23:0]  nxt_poly = ({7'b0, poly} << 7) + {17'b0, poly[16:10]} + 24'h018000;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            poly <= 17'd0; steps <= 4'd0; cyc_odd <= 1'b0;
        end else if (cen_E) begin
            cyc_odd <= ~cyc_odd;
            steps   <= cyc_odd ? 4'd13 : 4'd12;
        end else if (steps != 4'd0) begin
            // computed at 24 bits then masked to 17, as MAME's & POLY17_SIZE does
            poly  <= nxt_poly[16:0];
            steps <= steps - 4'd1;
        end
    end

    wire [7:0] random_q = poly[10:3];

    // ------------------------------------------------------------- reads
    // 9903 bit 7 is VBLANK, active high, replacing the input bit.
    // The last value the bus carried, for the open-bus reads below. Sampled at
    // the end of every CPU cycle, which is when the bus settles.
    logic [7:0] last_bus;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)     last_bus <= 8'h00;
        else if (cen_E) last_bus <= rnw ? cpu_d : din;
    end

    wire [7:0] floatv = OPEN_BUS ? last_bus : 8'h00;

    // cshift reads the WRITE-ONLY LS259 at 0x980c and 0x9810, so what an
    // undriven address returns is observable rather than theoretical. It is a
    // `CLR`, which reads, discards and writes zero, so nothing here depends on
    // the value -- but something elsewhere might.
    always_comb begin
        dout = floatv;
        if (in_rom)          dout = rom_q;
        else if (sel_rnd)    dout = random_q;
        else if (sel_inp)    dout = (addr[1:0] == 2'd0) ? in_swh
                                  : (addr[1:0] == 2'd1) ? in_swg
                                  : (addr[1:0] == 2'd2) ? in_in0
                                                        : {vblank, in_in1[6:0]};
        // The X2212s drive four bits; the top half of the byte floats.
        else if (sel_nv0 || sel_nv1) dout = {floatv[7:4], nv_q[3:0]};
        else if (sel_acia)   dout = acia_q;
        else if (sel_adc_r)  dout = adc_q;
    end

endmodule
