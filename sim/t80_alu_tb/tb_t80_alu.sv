// SPDX-License-Identifier: GPL-3.0-or-later
//
// T80's `SBC HL,DE` (ED 52), isolated.
//
// The 6VB calibration compares its measurement against a target with exactly
// this sequence, at 0x02AF-0x02BA of the audio ROM:
//
//     XOR A / LD H,A / LD L,A / SBC HL,DE   ; HL = -DE, the tick count
//     EX DE,HL / LD HL,(4061)               ; HL = the target
//     XOR A / SBC HL,DE                     ; HL = target - ticks
//     EXX / RET Z / JP M,02E8               ; branch on the SIGN
//
// The bus traces show T80 and MAME reaching that `JP M` having read exactly the
// same bytes and the same I/O, and branching differently. This runs the same
// arithmetic on its own and prints the result and the flags, so the question is
// answered by a number rather than by inference from a 1.2-million-line diff.
//
//   +de=%h   the measurement (the reading counter 1 gives)
//   +hl=%h   the target
//
// Writes HL after each SBC, then AF, then 1 or 0 for the branch, at 0x2000.
`timescale 1ns/1ps

module tb_t80_alu;

    logic clk = 0;
    always #62.5 clk = ~clk;
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
    logic [7:0] ram [0:16'h3fff];

    always_comb begin
        if (addr <= 16'h1fff)                          din = rom[addr];
        else if (addr >= 16'h2000 && addr <= 16'h5fff) din = ram[addr - 16'h2000];
        else                                           din = 8'h00;
    end

    always_ff @(posedge clk) if (clken)
        if (!mreq_n && iorq_n && rfsh_n && !wr_n && addr >= 16'h2000 && addr <= 16'h5fff)
            ram[addr - 16'h2000] <= dout;

    logic [15:0] de_in, hl_in;
    int          cyc = 0;

    function automatic void put(input int a, input logic [7:0] b);
        rom[a] = b;
    endfunction

    initial begin
        logic [31:0] v;
        logic [15:0] neg, diff, got_neg, got_diff, af;

        if (!$value$plusargs("de=%h", v)) v = 32'hD280;
        de_in = v[15:0];
        if (!$value$plusargs("hl=%h", v)) v = 32'h3BB8;
        hl_in = v[15:0];

        foreach (rom[i]) rom[i] = 8'h00;
        foreach (ram[i]) ram[i] = 8'h00;

        put('h00, 8'h31); put('h01, 8'hFF); put('h02, 8'h47);   // LD SP,47FF
        put('h03, 8'h11); put('h04, de_in[7:0]); put('h05, de_in[15:8]);
        put('h06, 8'hAF);                                        // XOR A
        put('h07, 8'h67);                                        // LD H,A
        put('h08, 8'h6F);                                        // LD L,A
        put('h09, 8'hED); put('h0A, 8'h52);                      // SBC HL,DE
        put('h0B, 8'h22); put('h0C, 8'h00); put('h0D, 8'h20);    // LD (2000),HL
        put('h0E, 8'hEB);                                        // EX DE,HL
        put('h0F, 8'h21); put('h10, hl_in[7:0]); put('h11, hl_in[15:8]);
        put('h12, 8'hAF);                                        // XOR A
        put('h13, 8'hED); put('h14, 8'h52);                      // SBC HL,DE
        put('h15, 8'hF5);                                        // PUSH AF
        put('h16, 8'h22); put('h17, 8'h02); put('h18, 8'h20);    // LD (2002),HL
        put('h19, 8'hE1);                                        // POP HL -> H=A, L=F
        put('h1A, 8'h22); put('h1B, 8'h04); put('h1C, 8'h20);    // LD (2004),HL
        put('h1D, 8'hD9);                                        // EXX
        put('h1E, 8'hFA); put('h1F, 8'h28); put('h20, 8'h00);    // JP M,0028
        put('h21, 8'h3E); put('h22, 8'h00);                      // LD A,0
        put('h23, 8'h32); put('h24, 8'h06); put('h25, 8'h20);    // LD (2006),A
        put('h26, 8'h18); put('h27, 8'h05);                      // JR +5 -> 002D
        put('h28, 8'h3E); put('h29, 8'h01);                      // LD A,1
        put('h2A, 8'h32); put('h2B, 8'h06); put('h2C, 8'h20);    // LD (2006),A
        put('h2D, 8'h76);                                        // HALT

        repeat (20) @(posedge clk);
        rst_n = 1;

        while (halt_n && cyc < 20000) begin
            @(posedge clk);
            cyc++;
        end
        if (halt_n) $fatal(1, "the program never halted");

        neg      = -de_in;
        diff     = hl_in - neg;
        got_neg  = {ram[16'h0001], ram[16'h0000]};
        got_diff = {ram[16'h0003], ram[16'h0002]};
        af       = {ram[16'h0005], ram[16'h0004]};   // H=A, L=F

        $display("DE=%04X  target=%04X", de_in, hl_in);
        $display("  SBC HL,DE with HL=0 : expect %04X, got %04X %s",
                 neg, got_neg, (neg == got_neg) ? "OK" : "MISMATCH");
        $display("  SBC HL,DE vs target : expect %04X, got %04X %s",
                 diff, got_diff, (diff == got_diff) ? "OK" : "MISMATCH");
        $display("  F = %02X  S=%0b Z=%0b H=%0b PV=%0b N=%0b C=%0b",
                 af[7:0], af[7], af[6], af[4], af[2], af[1], af[0]);
        $display("  expect S=%0b, branch %s; T80 %s",
                 diff[15], diff[15] ? "TAKEN" : "not taken",
                 ram[16'h0006] ? "TAKEN" : "not taken");
        if (af[7] !== diff[15])
            $display("FAIL the sign flag does not match the result's bit 15");
        else if (ram[16'h0006] !== diff[15])
            $display("FAIL the branch does not match the sign flag");
        else if (neg !== got_neg || diff !== got_diff)
            $display("FAIL the arithmetic is wrong");
        else
            $display("PASS");
        $finish;
    end

endmodule
