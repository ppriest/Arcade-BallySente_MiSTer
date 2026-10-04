// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/adc.sv against MAME: the main CPU's selects and reads of the ADC, with
// the analog ports held at known values (scripts/mame/adctrace.lua).
//
//   python scripts/mame_adc_trace.py minigolf 900
//   scripts/run_verilator.sh adc_tb +vec=debug/adc/minigolf_adc.vec
//
// Each select is replayed at MAME's time in clk_sys cycles and each read
// compared with what MAME's CPU read, except reads in the frame after the
// ports change, before the board's vblank latch has taken the new values.
`timescale 1ns/1ps

module tb_adc;

    logic clk = 0;
    always #12.5 clk = ~clk;
    logic rst_n = 0;

    logic       start = 0;
    logic [2:0] sel = '0;
    logic [7:0] an0 = '0, an1 = '0, an2 = '0, an3 = '0;
    logic [1:0] shift = '0;
    logic       raw = 0, raw_ob = 0;
    logic [7:0] q;

    adc dut (.clk, .rst_n, .start, .sel, .an0, .an1, .an2, .an3, .shift, .raw, .raw_ob, .q);

    initial begin
        string path, kind;
        int fd, r, nread, nbad, nskip;
        longint cyc, now;
        int a0, a1, a2, a3, ch, data, chk, sh, rw;

        if (!$value$plusargs("vec=%s", path)) path = "debug/adc/minigolf_adc.vec";
        fd = $fopen(path, "r");
        if (fd == 0) begin $display("FAIL: cannot open %s", path); $finish; end
        begin
            // "c <shift> <raw> [<offset binary>]"
            string ln;
            int    ob;
            ob = 0;
            void'($fgets(ln, fd));
            r = $sscanf(ln, "c %d %d %d", sh, rw, ob);
            raw_ob = ob[0];
        end
        shift = 2'(sh); raw = rw[0];

        repeat (4) @(posedge clk);
        rst_n = 1;
        now = 0; nread = 0; nbad = 0; nskip = 0;
        while ($fscanf(fd, "%s %d", kind, cyc) == 2) begin
            while (now < cyc) begin @(posedge clk); now++; end
            if (kind == "v") begin
                r = $fscanf(fd, "%h %h %h %h\n", a0, a1, a2, a3);
                an0 <= 8'(a0); an1 <= 8'(a1); an2 <= 8'(a2); an3 <= 8'(a3);
            end else if (kind == "s") begin
                r = $fscanf(fd, "%d\n", ch);
                start <= 1'b1; sel <= 3'(ch);
                @(posedge clk); now++;
                start <= 1'b0;
            end else begin
                r = $fscanf(fd, "%h %d\n", data, chk);
                if (chk == 0) nskip++;
                else begin
                    nread++;
                    if (q != 8'(data)) begin
                        nbad++;
                        if (nbad <= 10)
                            $display("MISMATCH at cycle %0d: rtl %02x, MAME %02x", cyc, q, data);
                    end
                end
            end
        end
        $display("%0d reads compared, %0d skipped (latch pending), %0d mismatches", nread, nskip, nbad);
        if (nbad == 0 && nread > 0) $display("PASS");
        else                        $display("FAIL");
        $finish;
    end

endmodule
