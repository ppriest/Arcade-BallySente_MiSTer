// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/sound/sente6vb_params.sv against scripts/cem3394_params.py, to the bit.
//
//   python scripts/cem3394_params.py vectors      # -> debug/cem3394/params_vectors.txt
//   scripts/run_verilator.sh params_tb
//
// Each vector is a write (chip mask, register, DAC code) and, for every chip it
// reached, the thirteen values the voice should then have. The write is
// applied as sente6vb_io presents it -- one cycle of cv_valid -- the unit is
// left to finish, and each reached voice is read back.
`timescale 1ns/1ps

module tb_params;

    logic clk = 0;
    always #12.5 clk = ~clk;
    logic rst_n = 0;

    logic        cv_valid = 0;
    logic [5:0]  cv_mask;
    logic [2:0]  cv_reg;
    logic [11:0] cv_dac;
    logic        busy;
    logic        commit = 0;
    logic [7:0]  overrun;
    logic [2:0]  rd_voice = 0;
    logic [31:0] step, inv_step, pw;
    logic [25:0] base_m, res, gcomp;
    logic signed [7:0] base_e;
    logic [26:0] mod_half, g_pulse, g_saw, g_tri, g_ext, g_final;

    sente6vb_params dut (.*);

    int fd, code, n_w = 0, n_e = 0, n_bad = 0, worst_cyc = 0, cyc;
    string line;
    int mask, rg, dac, v;
    longint exp_v [0:12];
    longint got [0:12];
    string names [0:12] = '{"step", "inv_step", "pw", "base_m", "base_e", "mod_half",
                            "res", "gcomp", "g_pulse", "g_saw", "g_tri", "g_ext", "g_final"};

    initial begin
        fd = $fopen("debug/cem3394/params_vectors.txt", "r");
        if (fd == 0) $fatal(1, "no vectors -- run scripts/cem3394_params.py vectors");
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        while (!$feof(fd)) begin
            line = "";
            void'($fgets(line, fd));
            if (line.len() == 0 || line.getc(0) == "#") continue;
            if (line.getc(0) == "W") begin
                void'($sscanf(line, "W %d %d %d", mask, rg, dac));
                @(posedge clk);
                cv_valid <= 1'b1; cv_mask <= 6'(mask); cv_reg <= 3'(rg); cv_dac <= 12'(dac);
                @(posedge clk);
                cv_valid <= 1'b0;
                cyc = 1;
                @(posedge clk);
                while (busy) begin @(posedge clk); cyc++; end
                if (cyc > worst_cyc) worst_cyc = cyc;
                commit <= 1'b1;
                @(posedge clk);
                commit <= 1'b0;
                @(posedge clk);
                n_w++;
            end else if (line.getc(0) == "E") begin
                void'($sscanf(line, "E %d %d %d %d %d %d %d %d %d %d %d %d %d %d", v,
                              exp_v[0], exp_v[1], exp_v[2], exp_v[3], exp_v[4], exp_v[5], exp_v[6],
                              exp_v[7], exp_v[8], exp_v[9], exp_v[10], exp_v[11], exp_v[12]));
                rd_voice = 3'(v);
                #1;
                got = '{step, inv_step, pw, base_m, base_e, mod_half, res, gcomp,
                        g_pulse, g_saw, g_tri, g_ext, g_final};
                n_e++;
                for (int i = 0; i < 13; i++) begin
                    if (got[i] != exp_v[i]) begin
                        n_bad++;
                        if (n_bad <= 15)
                            $display("MISMATCH write %0d (reg %0d dac %0d) voice %0d %s: got %0d want %0d",
                                     n_w, rg, dac, v, names[i], got[i], exp_v[i]);
                    end
                end
            end
        end
        $display("params_tb: %0d writes, %0d voice checks, %0d mismatches, worst job %0d cycles, %0d overruns",
                 n_w, n_e, n_bad, worst_cyc, overrun);
        if (n_bad == 0) $display("PASS bit-exact against scripts/cem3394_params.py");
        else            $display("FAIL");
        $finish;
    end

endmodule
