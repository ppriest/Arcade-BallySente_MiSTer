// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 0 criterion 5: the RTL ladder filter against the software model, to the
// bit. WORKFLOW section 9 -- the model is checked against MAME, the RTL against
// the model.
//
// Vectors come from `python scripts/cem3394_model.py vectors`, which writes the
// coefficients, the stimulus and the expected output as integers in the
// datapath's own format. A single mismatched LSB is a failure: this is an exact
// comparison, not a tolerance.
//
//   +vectors=<file>   debug/cem3394/lpf4_vectors.txt
//   +tanh=<file>      debug/cem3394/tanh_table.hex
//   +maxfail=<n>      stop printing after n mismatches (default 10)
`timescale 1ns/1ps

module tb_cem3394_lpf4;

    localparam int DW_INT  = 4;
    localparam int DW_FRAC = 26;
    localparam int DW      = DW_INT + DW_FRAC;
    localparam int CW_INT  = 4;
    localparam int CW_FRAC = 22;
    localparam int CW      = CW_INT + CW_FRAC;

    logic clk = 0;
    always #12.5 clk = ~clk;          // 40 MHz clk_sys
    logic rst_n = 0;

    logic signed [CW-1:0] alpha, beta0, beta1, beta2, beta3, alpha0, res, gain_comp;
    logic                 in_valid = 0;
    logic signed [DW-1:0] in_sample = 0;
    logic                 out_valid;
    logic signed [DW-1:0] out_sample;
    logic                 busy;

    string tanh_file;

    cem3394_lpf4 #(
        .DW_INT(DW_INT), .DW_FRAC(DW_FRAC), .CW_INT(CW_INT), .CW_FRAC(CW_FRAC),
        .TANH_LOG2N(10), .TANH_FILE("debug/cem3394/tanh_table.hex")
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .alpha(alpha), .beta0(beta0), .beta1(beta1), .beta2(beta2), .beta3(beta3),
        .alpha0(alpha0), .res(res), .gain_comp(gain_comp),
        .in_valid(in_valid), .in_sample(in_sample),
        .out_valid(out_valid), .out_sample(out_sample), .busy(busy)
    );

    int    fd, code, maxfail;
    string line, vec_file;
    int    n_points = 0, n_samples = 0, n_fail = 0;
    int    f_di, f_df, f_ci, f_cf, f_log2n, f_shift;
    longint got, exp_v, in_v;
    longint c_alpha, c_b0, c_b1, c_b2, c_b3, c_a0, c_res, c_gc, c_n;

    task automatic reset_dut();
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    task automatic run_sample(input longint s, output longint y);
        in_sample <= s[DW-1:0];
        in_valid  <= 1'b1;
        @(posedge clk);
        in_valid  <= 1'b0;
        while (!out_valid) @(posedge clk);
        y = $signed(out_sample);
        @(posedge clk);
    endtask

    initial begin
        if (!$value$plusargs("vectors=%s", vec_file))
            vec_file = "debug/cem3394/lpf4_vectors.txt";
        if (!$value$plusargs("maxfail=%d", maxfail)) maxfail = 10;

        fd = $fopen(vec_file, "r");
        if (fd == 0) $fatal(1, "cannot open %s -- run: python scripts/cem3394_model.py vectors",
                            vec_file);

        // The model writes the format it used; refuse to run against a
        // mismatch rather than report a sea of failures.
        code = $fscanf(fd, "# format %d %d %d %d %d %d\n",
                       f_di, f_df, f_ci, f_cf, f_log2n, f_shift);
        if (code != 6) $fatal(1, "%s: no format header", vec_file);
        if (f_di != DW_INT || f_df != DW_FRAC || f_ci != CW_INT || f_cf != CW_FRAC)
            $fatal(1, "vector format Q%0d.%0d/Q%0d.%0d does not match this bench's Q%0d.%0d/Q%0d.%0d",
                   f_di, f_df, f_ci, f_cf, DW_INT, DW_FRAC, CW_INT, CW_FRAC);
        void'($fgets(line, fd));      // the "# rate ..." line

        reset_dut();

        forever begin
            code = $fscanf(fd, "C %d %d %d %d %d %d %d %d %d\n",
                           c_alpha, c_b0, c_b1, c_b2, c_b3, c_a0, c_res, c_gc, c_n);
            if (code != 9) break;
            n_points++;
            alpha     = c_alpha[CW-1:0];
            beta0     = c_b0[CW-1:0];
            beta1     = c_b1[CW-1:0];
            beta2     = c_b2[CW-1:0];
            beta3     = c_b3[CW-1:0];
            alpha0    = c_a0[CW-1:0];
            res       = c_res[CW-1:0];
            gain_comp = c_gc[CW-1:0];
            // Each operating point starts from a clean filter, as the model does.
            reset_dut();

            for (int i = 0; i < c_n; i++) begin
                code = $fscanf(fd, "S %d %d\n", in_v, exp_v);
                if (code != 2) $fatal(1, "vector file ended inside point %0d", n_points);
                run_sample(in_v, got);
                n_samples++;
                if (got !== exp_v) begin
                    n_fail++;
                    if (n_fail <= maxfail)
                        $display("MISMATCH point %0d sample %0d: in %0d  model %0d  rtl %0d  (delta %0d)",
                                 n_points, i, in_v, exp_v, got, got - exp_v);
                end
            end
        end
        $fclose(fd);

        $display("cem3394_lpf4: %0d operating points, %0d samples, %0d mismatches",
                 n_points, n_samples, n_fail);
        if (n_samples == 0) $fatal(1, "no vectors were run");
        if (n_fail == 0) $display("PASS bit-exact against scripts/cem3394_model.py");
        else             $display("FAIL %0d of %0d samples differ", n_fail, n_samples);
        $finish;
    end

endmodule
