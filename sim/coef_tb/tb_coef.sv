// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/sound/cem3394_coef.sv against scripts/cem3394_coef.py, to the bit.
//
//   python scripts/cem3394_coef.py vectors        # -> debug/cem3394/coef_vectors.txt
//   scripts/run_verilator.sh coef_tb
//
// Each vector is one voice-sample's inputs -- the four waveforms, the four
// mixer gains, the base cutoff, the FM depth, the resonance -- and the mix and
// six coefficients the specification computes from them.
`timescale 1ns/1ps

module tb_coef;

    logic clk = 0;
    always #12.5 clk = ~clk;
    logic rst_n = 0;

    logic        start = 0, done;
    logic signed [29:0] ramp, pulse, triang, ext, mix;
    logic [26:0] g_saw, g_pulse, g_tri, g_ext, mod_half;
    logic [25:0] base_m, res;
    logic signed [7:0] base_e;
    logic signed [25:0] alpha, beta0, beta1, beta2, beta3, alpha0;

    cem3394_coef dut (.*);

    int fd, n = 0, n_bad = 0, cyc, worst = 0;
    string line;
    longint v [0:19];
    longint got [0:6];
    string names [0:6] = '{"mix", "alpha", "beta0", "beta1", "beta2", "beta3", "alpha0"};

    initial begin
        fd = $fopen("debug/cem3394/coef_vectors.txt", "r");
        if (fd == 0) $fatal(1, "no vectors -- run scripts/cem3394_coef.py vectors");
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        while (!$feof(fd)) begin
            line = "";
            void'($fgets(line, fd));
            if (line.len() == 0 || line.getc(0) == "#") continue;
            void'($sscanf(line, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                          v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9],
                          v[10], v[11], v[12], v[13], v[14], v[15], v[16], v[17], v[18], v[19]));
            @(posedge clk);
            ramp <= 30'(v[0]); pulse <= 30'(v[1]); triang <= 30'(v[2]); ext <= 30'(v[3]);
            g_saw <= 27'(v[4]); g_pulse <= 27'(v[5]); g_tri <= 27'(v[6]); g_ext <= 27'(v[7]);
            base_m <= 26'(v[8]); base_e <= 8'(v[9]); mod_half <= 27'(v[10]); res <= 26'(v[11]);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            cyc = 1;
            while (!done) begin @(posedge clk); cyc++; end
            if (cyc > worst) worst = cyc;
            got = '{mix, alpha, beta0, beta1, beta2, beta3, alpha0};
            for (int i = 0; i < 7; i++)
                if (got[i] != v[12 + i]) begin
                    n_bad++;
                    if (n_bad <= 12)
                        $display("MISMATCH vector %0d %s: got %0d want %0d", n, names[i], got[i], v[12 + i]);
                end
            n++;
        end
        $display("coef_tb: %0d vectors, %0d mismatches, %0d cycles each", n, n_bad, worst);
        if (n_bad == 0) $display("PASS bit-exact against scripts/cem3394_coef.py");
        else            $display("FAIL");
        $finish;
    end

endmodule
