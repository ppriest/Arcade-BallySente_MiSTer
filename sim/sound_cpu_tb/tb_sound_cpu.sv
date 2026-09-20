// SPDX-License-Identifier: GPL-3.0-or-later
//
// The 6VB's sound Z80 (T80) booting the audio board's own ROM, diffed against
// MAME's bus trace. This is T80's verification in this repository: upstream
// ships no testbench, so the substitute recorded in rtl/cpu/t80/PROVENANCE.md
// is the same bus-trace diff mc6809i got.
//
// The 6VB memory map (sente6vb.cpp mem_map):
//   0000-1FFF  ROM, the audio board's own, identical for every cartridge
//   2000-5FFF  RAM
//   6000-6001  (mirror 0x1ffe) ACIA write, to the main board
//   E000-E001  (mirror 0x1ffe) ACIA read, from the main board
//
// I/O space (io_map, global mask 0xff) is NOT compared: MAME's write tap is on
// the program space, so the 8253 and the CEM3394 control ports do not appear in
// the reference. The Z80's OUT instructions still execute here; their effects
// simply are not checked. What IS checked is the program's memory behaviour,
// which is the strong signal that the CPU core is executing correctly.
//
//   +rom=<file>     debug/rom/sente6vb_audiocpu.hex
//   +replay=<file>  debug/sente6vb-boot/sente6vb_replay.txt
//   +trace=<file>   debug/sente6vb-boot/sente6vb_rtl.trace
//   +maxacc=<n>     stop after n bus cycles
`timescale 1ns/1ps

module tb_sound_cpu;

    // The 6VB Z80 runs at 8 MHz / 2 = 4 MHz (sente6vb.cpp:107). Here it is
    // clocked every cycle: the bench compares the ORDER of bus accesses, not
    // their spacing in time.
    logic clk = 0;
    always #62.5 clk = ~clk;             // 8 MHz, CLKEN every other cycle
    logic rst_n = 0;
    logic clken = 0;
    always_ff @(posedge clk) clken <= ~clken;

    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
    wire [15:0] addr;
    wire [7:0]  dout;
    logic [7:0] din;

    T80se #(.Mode(0), .T2Write(0), .IOWait(1)) u_cpu (
        .RESET_n(rst_n), .CLK_n(clk), .CLKEN(clken),
        .WAIT_n(1'b1), .INT_n(1'b1), .NMI_n(1'b1), .BUSRQ_n(1'b1),
        .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
        .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n),
        .HALT_n(halt_n), .BUSAK_n(busak_n),
        .A(addr), .DI(din), .DO(dout)
    );

    logic [7:0] rom [0:16'h1fff];
    logic [7:0] ram [0:16'h3fff];        // 2000-5FFF

    localparam int MAXIO = 1 << 16;
    logic [15:0] io_addr [0:MAXIO-1];
    logic [7:0]  io_data [0:MAXIO-1];
    int io_n = 0, io_i = 0, io_over = 0;

    function automatic bit is_rom(input logic [15:0] a);
        return a <= 16'h1fff;
    endfunction
    function automatic bit is_ram(input logic [15:0] a);
        return (a >= 16'h2000) && (a <= 16'h5fff);
    endfunction

    always_comb begin
        if (is_rom(addr))      din = rom[addr];
        else if (is_ram(addr)) din = ram[addr - 16'h2000];
        else                   din = (io_i < io_n) ? io_data[io_i] : 8'h00;
    end

    int    fd, acc = 0, maxacc;
    string rom_file, replay_file, trace_file;

    // One access per completed bus cycle: MREQ with RD or WR, and not a refresh.
    logic mreq_d, rd_d, wr_d;
    always_ff @(posedge clk) if (clken) begin
        mreq_d <= mreq_n; rd_d <= rd_n; wr_d <= wr_n;
    end

    task automatic load_replay();
        int f, code;
        logic [31:0] a, m, d;
        f = $fopen(replay_file, "r");
        if (f == 0) begin
            $display("NOTE  no replay file at %s; non-RAM/ROM reads answer 00", replay_file);
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
        $display("NOTE  %0d replayed reads from %s", io_n, replay_file);
    endtask

    initial begin
        if (!$value$plusargs("rom=%s", rom_file))       rom_file = "debug/rom/sente6vb_audiocpu.hex";
        if (!$value$plusargs("replay=%s", replay_file)) replay_file = "debug/sente6vb-boot/sente6vb_replay.txt";
        if (!$value$plusargs("trace=%s", trace_file))   trace_file = "debug/sente6vb-boot/sente6vb_rtl.trace";
        if (!$value$plusargs("maxacc=%d", maxacc))      maxacc = 60000;

        foreach (rom[i]) rom[i] = 8'h00;
        foreach (ram[i]) ram[i] = 8'h00;
        $readmemh(rom_file, rom);
        if (rom[0] === 8'h00 && rom[1] === 8'h00)
            $display("WARNING  the ROM image looks empty -- check the path and the CWD");
        load_replay();

        fd = $fopen(trace_file, "w");
        if (fd == 0) $fatal(1, "cannot write %s", trace_file);
        $fwrite(fd, "# RTL 6VB sound-CPU bus accesses from reset, in order.\n");
        $fwrite(fd, "# seq\trw\taddr\tmask\tdata\n");

        repeat (20) @(posedge clk);
        rst_n = 1;
    end

    // A memory access completes on the clk_en edge where MREQ is asserted with
    // RD or WR and RFSH is not. Sampling once per bus cycle rather than per
    // T-state keeps this one line per MAME access.
    logic acc_seen;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_seen <= 1'b0;
        end else if (clken) begin
            if (!mreq_n && rfsh_n && (!rd_n || !wr_n)) begin
                if (!acc_seen) begin
                    acc_seen <= 1'b1;
                    acc <= acc + 1;
                    if (!wr_n) begin
                        if (is_ram(addr)) ram[addr - 16'h2000] <= dout;
                        $fwrite(fd, "%0d\tw\t%04X\tFF\t%02X\n", acc + 1, addr, dout);
                    end else begin
                        if (!is_rom(addr) && !is_ram(addr)) begin
                            if (io_i < io_n) io_i <= io_i + 1;
                            else             io_over <= io_over + 1;
                        end
                        $fwrite(fd, "%0d\tr\t%04X\tFF\t%02X\n", acc + 1, addr, din);
                    end
                    if (acc + 1 >= maxacc) begin
                        $fwrite(fd, "# %0d accesses logged\n", acc + 1);
                        $fclose(fd);
                        $display("RTLTRACE %0d accesses -> %s", acc + 1, trace_file);
                        if (io_over > 0)
                            $display("WARN  %0d reads past the end of the replay answered 00",
                                     io_over);
                        $finish;
                    end
                end
            end else begin
                acc_seen <= 1'b0;
            end
        end
    end

endmodule
