// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shrike Avenger's second board: a 68000 with its own 16 KB program, 4 KB of
// RAM shared with the 6809, and sixteen I/O words, as MAME models it
// (balsente.cpp shrike68k_map and cpu1_shrike_map, balsente_m.cpp shrike_*).
//
// Adapted from shrike_68k_board.sv in misteraddons' Arcade-BallySenteSAC1_MiSTer
// (commit 3f015f22), used under GPL-3.0 with its author's permission
// (THIRD-PARTY.md): the clock enables, reset and RAMs are this core's.
//
// 68000 map, no interrupts, no wait states:
//   000000-003FFF  program ROM, savgu22 on the even (high) bytes, savgu24 on
//                  the odd (low) bytes
//   010000-01001F  sixteen I/O words, written by byte; a read of one byte of a
//                  word returns it in the low byte (shrike_io_68k_r shifts by
//                  8 & ~mem_mask), the even byte alone reading 0
//   018000-018FFF  the shared RAM
//   elsewhere      reads 0
//
// The 6809 sees the shared RAM at 9E00-9FFF, byte n of it big-endian (even
// is the word's high byte). Two exceptions (shrike_shared_6809_r/_w): 9E06
// reads 0, MAME's "motors OK" until the motion base is modelled -- MAME has
// none -- and a write to 9E01 also selects the sprite bank
// (shrike_sprite_select_w). MAME computes that bank as (data & 0x80 >> 7) ^ 1,
// which C parses as (data & 1) ^ 1: data bit 0 clear selects the upper 64 KB.
// docs/MAME_KLUDGES.md has the entry.
//
// Clock: MAME runs the 68000 at 8 MHz. FX68K takes alternating phase enables,
// two per 68000 clock, so 16 MHz of them from 40 MHz: an accumulator adds 2
// in 5, an enable every 2.5 clocks on average. Pause holds them.

module shrike_board (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        pause,

    // the 6809 at 9E00-9FFF; we is one clock per write
    input  logic [8:0]  cpu_addr,
    input  logic [7:0]  cpu_din,
    input  logic        cpu_we,
    output logic [7:0]  cpu_q,
    output logic        sprite_hi,      // the upper 64 KB of sprites

    // the program ROM from the download: 0000-1FFF savgu22, 2000-3FFF savgu24
    input  logic        dl_we,
    input  logic [13:0] dl_addr,
    input  logic [7:0]  dl_data
);

    // ------------------------------------------------------------- clock
    logic [2:0] acc;
    logic       phi, en1, en2;
    always_ff @(posedge clk) begin
        en1 <= 1'b0; en2 <= 1'b0;
        if (!pause || !rst_n) begin
            if (acc >= 3'd3) begin
                acc <= acc - 3'd3;
                phi <= ~phi;
                en1 <= ~phi;
                en2 <=  phi;
            end else
                acc <= acc + 3'd2;
        end
    end

    // --------------------------------------------------------------- CPU
    wire        rw, as_n, uds_n, lds_n;
    wire [23:1] a;
    wire [15:0] dout;
    logic [15:0] din;

    fx68k u_68k (
        .clk(clk), .HALTn(1'b1), .extReset(!rst_n), .pwrUp(!rst_n),
        .enPhi1(en1), .enPhi2(en2),
        .eRWn(rw), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n),
        .E(), .VMAn(), .FC0(), .FC1(), .FC2(), .BGn(), .oRESETn(), .oHALTEDn(),
        .DTACKn(as_n), .VPAn(1'b1), .BERRn(1'b1), .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(1'b1), .IPL1n(1'b1), .IPL2n(1'b1),
        .iEdb(din), .oEdb(dout), .eab(a)
    );

    wire       cs_rom = a[23:14] == 10'h000;
    wire       cs_io  = a[23:5]  == 19'h00800;       // 010000-01001F
    wire       cs_sh  = a[23:12] == 12'h018;         // 018000-018FFF
    wire [1:0] be     = {!uds_n, !lds_n};
    wire       wr     = !as_n && !rw && (|be);

    // ------------------------------------------------------ program ROM
    logic [7:0] rom_hi [0:8191], rom_lo [0:8191];
    logic [7:0] rom_hi_q, rom_lo_q;
    always_ff @(posedge clk) begin
        if (dl_we && !dl_addr[13]) rom_hi[dl_addr[12:0]] <= dl_data;
        rom_hi_q <= rom_hi[a[13:1]];
    end
    always_ff @(posedge clk) begin
        if (dl_we && dl_addr[13]) rom_lo[dl_addr[12:0]] <= dl_data;
        rom_lo_q <= rom_lo[a[13:1]];
    end

    // ------------------------------------------------------ shared RAM
    // One true dual-port RAM per byte lane, port A the 68000's, port B the
    // 6809's (rtl/memory/dpram_tdp.sv).
    logic [7:0] sh_hi_q, sh_lo_q, sh_hi_b, sh_lo_b;
    wire  [10:0] b_addr = {3'd0, cpu_addr[8:1]};
    dpram_tdp #(.ADDR_WIDTH(11)) u_sh_hi (
        .clk(clk),
        .a_addr(a[11:1]), .a_we(cs_sh && wr && be[1]), .a_wdata(dout[15:8]), .a_rdata(sh_hi_q),
        .b_addr(b_addr), .b_we(cpu_we && !cpu_addr[0]), .b_wdata(cpu_din), .b_rdata(sh_hi_b)
    );
    dpram_tdp #(.ADDR_WIDTH(11)) u_sh_lo (
        .clk(clk),
        .a_addr(a[11:1]), .a_we(cs_sh && wr && be[0]), .a_wdata(dout[7:0]), .a_rdata(sh_lo_q),
        .b_addr(b_addr), .b_we(cpu_we && cpu_addr[0]), .b_wdata(cpu_din), .b_rdata(sh_lo_b)
    );

    // ------------------------------------------------------- I/O words
    logic [15:0] io [0:15];
    always_ff @(posedge clk) begin
        if (cs_io && wr) begin
            if (be[1]) io[a[4:1]][15:8] <= dout[15:8];
            if (be[0]) io[a[4:1]][7:0]  <= dout[7:0];
        end
    end
    wire [15:0] io_q = io[a[4:1]];

    always_comb begin
        if (cs_rom)     din = {rom_hi_q, rom_lo_q};
        else if (cs_sh) din = {sh_hi_q, sh_lo_q};
        else if (cs_io) din = (&be) ? io_q : {8'h00, io_q[7:0]};
        else            din = 16'h0000;
    end

    // ------------------------------------------------------------ 6809
    assign cpu_q = (cpu_addr == 9'h006) ? 8'h00 : cpu_addr[0] ? sh_lo_b : sh_hi_b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                             sprite_hi <= 1'b0;
        else if (cpu_we && cpu_addr == 9'h001)  sprite_hi <= !cpu_din[0];
    end

endmodule
