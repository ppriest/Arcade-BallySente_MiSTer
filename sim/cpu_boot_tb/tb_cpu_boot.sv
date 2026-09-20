// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 0 gate, criterion 2: the MC6809E boots a set's program ROM and its bus
// accesses match MAME's, access by access (scripts/compare_boot_trace.py).
//
// The board is stubbed down to what the CPU can see: RAM, the cartridge ROM
// window mapper, and a replay of the I/O reads MAME's CPU got at the same
// points. Nothing else exists yet -- no video, no sound, no interrupts. The
// IRQ/FIRQ lines are held inactive, so the comparison is valid only over the
// window before the first interrupt MAME took; the runner reports where that is.
//
//   +rom=<file>       debug/rom/<set>_maincpu.hex, one byte per line
//   +replay=<file>    debug/<set>-boot/<set>_replay.txt ("ADDR MASK DATA" hex)
//   +trace=<file>     debug/<set>-boot/<set>_rtl.trace
//   +maxacc=<n>       stop after n bus cycles
//   +cdmask=<h>       cartridge CD-bank mask (expand_roms argument, low 6 bits)
//   +swap=<0|1>       SWAP_HALVES
//   +banks=<8|16>     bank count; 16 when the maincpu region is 256 KB
`timescale 1ns/1ps

module tb_cpu_boot;

    // 40 MHz clk_sys: every board clock divides exactly out of it (docs/ROADMAP.md).
    localparam real CLK_NS = 25.0;
    // E is clk_sys/32 = 1.25 MHz. Q leads E by a quarter of the E period, as
    // jtframe_6809wait phases them (cen_E at count 0, cen_Q a half-phase later).
    localparam int  ECYC   = 32;

    logic clk = 0;
    always #(CLK_NS / 2.0) clk = ~clk;

    logic [4:0] phase = 0;
    logic cen_E, cen_Q;
    always @(posedge clk) phase <= phase + 5'd1;
    assign cen_E = (phase == 5'd0);
    assign cen_Q = (phase == 5'd16);

    logic nRESET = 0;

    // ---------------------------------------------------------------- CPU
    wire [15:0] ADDR;
    wire [7:0]  DOut;
    wire        RnW, BS, BA, AVMA, BUSY, LIC, OP;
    logic [7:0] D;

    mc6809i #(.ILLEGAL_INSTRUCTIONS("GHOST")) u_cpu (
        .D(D), .DOut(DOut), .ADDR(ADDR), .RnW(RnW),
        .clk(clk), .cen_E(cen_E), .cen_Q(cen_Q),
        .BS(BS), .BA(BA),
        .nIRQ(1'b1), .nFIRQ(1'b1), .nNMI(1'b1),
        .AVMA(AVMA), .BUSY(BUSY), .LIC(LIC),
        .nHALT(1'b1), .nRESET(nRESET), .nDMABREQ(1'b1),
        .OP(OP), .RegData()
    );

    // ------------------------------------------------------------- memory
    // 0x0000-0x07ff internal RAM (0x0000-0x00ff of it is sprite RAM)
    // 0x0800-0x7fff video bitmap
    // 0x8000-0x8fff palette RAM
    // One array: the CPU sees them all as plain read/write memory.
    logic [7:0] ram [0:16'h8fff];

    // The cartridge program ROM region, 128 KB or 256 KB.
    logic [7:0] prg [0:18'h3ffff];

    int cdmask, swap, banks, maxacc;
    string rom_file, replay_file, trace_file;

    // --------------------------------------------------- cartridge mapper
    // balsente.cpp:2914 expand_roms(). Bank pointers, not a ROM transform:
    // every window is base + 0x2000*n, optionally with 0x2000 XORed in.
    logic [3:0] bank_ab = 0, bank_cd = 0;
    logic       bank_ef = 0;

    function automatic int unsigned bxor();
        return swap ? 'h2000 : 0;
    endfunction

    // The 8-bank group a bank number falls in: group 1 lives 0x20000 higher.
    function automatic int unsigned grp_base(input logic [3:0] b);
        return (b >= 8) ? 'h20000 : 0;
    endfunction

    function automatic int unsigned map_ab(input logic [15:0] a);
        automatic int unsigned n = bank_ab & 4'h7;
        return grp_base(bank_ab) + (('h2000 * n) ^ bxor()) + (a - 'ha000);
    endfunction

    function automatic int unsigned map_cd(input logic [15:0] a);
        automatic int unsigned n = bank_cd & 4'h7;
        // Banks 6 and 7 always take the common CD ROM, and so does any bank
        // whose mask bit is clear.
        if (n >= 6 || ((cdmask >> n) & 1) == 0)
            return grp_base(bank_cd) + ('h1c000 ^ bxor()) + (a - 'hc000);
        return grp_base(bank_cd) + 'h10000 + (('h2000 * n) ^ bxor()) + (a - 'hc000);
    endfunction

    function automatic int unsigned map_ef(input logic [15:0] a);
        return (bank_ef ? 'h20000 : 0) + ('h1e000 ^ bxor()) + (a - 'he000);
    endfunction

    // ------------------------------------------------------- I/O replay
    // MAME's I/O reads in order. The bench does not model any peripheral yet;
    // it answers with what MAME's CPU was given at the same point.
    localparam int MAXIO = 1 << 18;
    logic [15:0] io_addr [0:MAXIO-1];
    logic [7:0]  io_data [0:MAXIO-1];
    int io_n = 0, io_i = 0, io_over = 0, io_addr_bad = 0;

    function automatic bit is_io(input logic [15:0] a);
        return (a >= 16'h9000) && (a <= 16'h9fff);
    endfunction

    // Read data: combinational, so it is stable at the cen_E that ends the cycle.
    logic [7:0] io_q;
    always_comb begin
        if (ADDR <= 16'h8fff)      D = ram[ADDR];
        else if (is_io(ADDR))      D = io_q;
        else if (ADDR <= 16'hbfff) D = prg[map_ab(ADDR)];
        else if (ADDR <= 16'hdfff) D = prg[map_cd(ADDR)];
        else                       D = prg[map_ef(ADDR)];
    end
    assign io_q = (io_i < io_n) ? io_data[io_i] : 8'h00;

    // ------------------------------------------------------------- trace
    int fd, acc = 0;
    // CPI. Every memory answer here is same-cycle, so the stall component is
    // zero by construction and `acc` is pure execution; SDRAM stalls are
    // measured later, against the real memory transport.
    int opfetch = 0, deadcyc = 0, wrcyc = 0;

    task automatic load_replay();
        int f, code;
        logic [31:0] a, m, d;
        f = $fopen(replay_file, "r");
        if (f == 0) begin
            $display("NOTE  no replay file at %s; I/O reads will answer 00", replay_file);
            return;
        end
        forever begin
            code = $fscanf(f, "%h %h %h\n", a, m, d);
            if (code != 3) break;
            if (io_n < MAXIO) begin
                io_addr[io_n] = a[15:0];
                io_data[io_n] = d[7:0];
                io_n++;
            end
        end
        $fclose(f);
        $display("NOTE  %0d I/O reads loaded from %s", io_n, replay_file);
    endtask

    initial begin
        if (!$value$plusargs("rom=%s", rom_file))       rom_file = "debug/rom/sentetst_maincpu.hex";
        if (!$value$plusargs("replay=%s", replay_file)) replay_file = "debug/sentetst-boot/sentetst_replay.txt";
        if (!$value$plusargs("trace=%s", trace_file))   trace_file = "debug/sentetst-boot/sentetst_rtl.trace";
        if (!$value$plusargs("maxacc=%d", maxacc))      maxacc = 20000;
        if (!$value$plusargs("cdmask=%d", cdmask))      cdmask = 0;
        if (!$value$plusargs("swap=%d", swap))          swap = 0;
        if (!$value$plusargs("banks=%d", banks))        banks = 8;

        foreach (ram[i]) ram[i] = 8'h00;
        foreach (prg[i]) prg[i] = 8'h00;
        $readmemh(rom_file, prg);
        load_replay();

        fd = $fopen(trace_file, "w");
        if (fd == 0) $fatal(1, "cannot write %s", trace_file);
        $fwrite(fd, "# RTL main-CPU bus accesses from reset, in order.\n");
        $fwrite(fd, "# seq\trw\taddr\tmask\tdata\n");

        repeat (8 * ECYC) @(posedge clk);
        nRESET <= 1;
    end

    // One bus cycle completes at each cen_E: the address, direction and write
    // data presented for it are the values in flight before that edge.
    always @(posedge clk) begin
        if (nRESET && cen_E) begin
            acc <= acc + 1;
            if (OP)                 opfetch <= opfetch + 1;
            if (ADDR == 16'hffff)   deadcyc <= deadcyc + 1;
            if (!RnW)               wrcyc   <= wrcyc + 1;
            if (RnW) begin
                if (is_io(ADDR)) begin
                    if (io_i < io_n) begin
                        if (io_addr[io_i] !== ADDR) io_addr_bad <= io_addr_bad + 1;
                        io_i <= io_i + 1;
                    end else begin
                        io_over <= io_over + 1;
                    end
                end
                $fwrite(fd, "%0d\tr\t%04X\tFF\t%02X\n", acc + 1, ADDR, D);
            end else begin
                if (ADDR <= 16'h8fff) ram[ADDR] <= DOut;
                // 0x98a0-0x98bf: rombank_select_w -- bits 6:4 set AB and CD, EF to 0
                if (ADDR >= 16'h98a0 && ADDR <= 16'h98bf) begin
                    bank_ab <= {1'b0, DOut[6:4]};
                    bank_cd <= {1'b0, DOut[6:4]};
                    bank_ef <= 1'b0;
                end
                // 0x9f00: rombank2_select_w -- st1002 cartridges only
                if (ADDR == 16'h9f00) begin
                    automatic logic [3:0] b = {(banks > 8) ? DOut[7] : 1'b0, DOut[2:0]};
                    if (DOut[5]) begin
                        bank_ab <= b;
                        bank_cd <= 4'd6;
                        bank_ef <= 1'b0;
                    end else begin
                        bank_ab <= b;
                        bank_cd <= b;
                        bank_ef <= b[3];
                    end
                end
                $fwrite(fd, "%0d\tw\t%04X\tFF\t%02X\n", acc + 1, ADDR, DOut);
            end

            if (acc + 1 >= maxacc) begin
                $fwrite(fd, "# %0d accesses logged\n", acc + 1);
                $fclose(fd);
                $display("RTLTRACE %0d accesses -> %s", acc + 1, trace_file);
                $display("CPI      %0d bus cycles, %0d opcode fetches, %0d writes, %0d dead ($FFFF)",
                         acc + 1, opfetch, wrcyc, deadcyc);
                $display("CPI      %0.3f bus cycles per opcode fetch, zero memory stall by construction",
                         real'(acc + 1) / real'(opfetch));
                if (io_over > 0)
                    $display("WARN  %0d I/O reads past the end of the replay answered 00", io_over);
                if (io_addr_bad > 0)
                    $display("WARN  %0d I/O reads hit a different address than MAME's", io_addr_bad);
                $finish;
            end
        end
    end

endmodule
