// SPDX-License-Identifier: GPL-3.0-or-later
//
// The RTL oscillator against VCOFixed in scripts/cem3394_model.py, to the bit.
// Vectors from `python scripts/cem3394_model.py vectors`.
//
//   +vectors=<file>   debug/cem3394/vco_vectors.txt
//   +maxfail=<n>      stop printing after n mismatches (default 10)
`timescale 1ns/1ps

module tb_cem3394_vco;

    localparam int PH_BITS = 32;
    localparam int P_FRAC  = 26;
    localparam int DW      = P_FRAC + 4;

    logic clk = 0;
    always #12.5 clk = ~clk;
    logic rst_n = 0;

    logic [PH_BITS-1:0] step, inv_step, pw;
    logic               in_valid = 0, out_valid, busy;
    logic signed [DW-1:0] ramp, pulse, triang;

    cem3394_vco #(.PH_BITS(PH_BITS), .P_FRAC(P_FRAC)) dut (
        .clk(clk), .rst_n(rst_n),
        .step(step), .inv_step(inv_step), .pw(pw),
        .in_valid(in_valid), .out_valid(out_valid),
        .ramp(ramp), .pulse(pulse), .triang(triang), .busy(busy)
    );

    int      fd, code, maxfail, cycles, worst_cycles = 0;

    // Per-sample cycle cost, kept per setting so the SIX-VOICE budget can be
    // read off rather than estimated from the worst case. A shared pipeline
    // computes all six voices inside one sample period, so what has to fit is
    // the sum across voices at the same sample index, not six times the worst
    // sample any one voice ever has. docs/HACKS.md, "The six-voice sound
    // pipeline does not fit one shared instance at 40 MHz".
    localparam int MAXSET = 8;
    localparam int MAXSAM = 4096;
    int      cyc [0:MAXSET-1][0:MAXSAM-1];
    int      set_n [0:MAXSET-1];
    longint  cyc_total = 0;
    string   vec_file;
    int      f_ph, f_inv, f_t, f_p;
    int      n_sets = 0, n_samples = 0, n_fail = 0;
    longint  v_step, v_inv, v_pw, v_n;
    longint  e_ph, e_r, e_p, e_t;

    // The six-voice sum, sample by sample: what a shared pipeline has to fit.
    task automatic report_budget();
        int nv, ns, sum, worst_sum, over, filtcyc;
        longint tot;
        int hist [0:63];
        if (!$value$plusargs("filtcyc=%d", filtcyc)) filtcyc = 41;
        nv = (n_sets < MAXSET) ? n_sets : MAXSET;
        ns = MAXSAM;
        for (int v = 0; v < nv; v++) if (set_n[v] < ns) ns = set_n[v];
        if (nv == 0 || ns == 0) return;
        foreach (hist[k]) hist[k] = 0;
        worst_sum = 0; tot = 0;
        for (int i = 0; i < ns; i++) begin
            sum = 0;
            for (int v = 0; v < nv; v++) sum += cyc[v][i];
            tot += sum;
            if (sum > worst_sum) worst_sum = sum;
            hist[(sum / 32 < 64) ? sum / 32 : 63]++;
        end
        $display("  mean %0d cycles/sample/voice over %0d samples",
                 int'(cyc_total / n_samples), n_samples);
        $display("  %0d voices together: mean %0d, worst %0d cycles per sample period",
                 nv, int'(tot / ns), worst_sum);
        // The filter's cost is fixed -- sim/cem3394_lpf4_tb prints it and checks
        // that best and worst agree -- so it is added rather than measured here.
        $display("  plus %0d filter cycles (%0d each): mean %0d, worst %0d",
                 nv * filtcyc, filtcyc, int'(tot / ns) + nv * filtcyc,
                 worst_sum + nv * filtcyc);
        for (int b = 0; b < 64; b++)
            if (hist[b]) $display("    %4d-%4d cycles : %0d samples", b * 32, b * 32 + 31, hist[b]);
    endtask

    task automatic reset_dut();
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    initial begin
        if (!$value$plusargs("vectors=%s", vec_file))
            vec_file = "debug/cem3394/vco_vectors.txt";
        if (!$value$plusargs("maxfail=%d", maxfail)) maxfail = 10;

        fd = $fopen(vec_file, "r");
        if (fd == 0) $fatal(1, "cannot open %s -- run: python scripts/cem3394_model.py vectors",
                            vec_file);
        code = $fscanf(fd, "# format %d %d %d %d\n", f_ph, f_inv, f_t, f_p);
        if (code != 4) $fatal(1, "%s: no format header", vec_file);
        if (f_ph != PH_BITS || f_p != P_FRAC)
            $fatal(1, "vector format %0d/%0d does not match this bench's %0d/%0d",
                   f_ph, f_p, PH_BITS, P_FRAC);
        void'($fscanf(fd, "# rate %d\n", code));

        reset_dut();

        forever begin
            code = $fscanf(fd, "V %d %d %d %d\n", v_step, v_inv, v_pw, v_n);
            if (code != 4) break;
            n_sets++;
            step     = v_step[PH_BITS-1:0];
            inv_step = v_inv[PH_BITS-1:0];
            pw       = v_pw[PH_BITS-1:0];
            reset_dut();

            for (int i = 0; i < v_n; i++) begin
                code = $fscanf(fd, "S %d %d %d %d\n", e_ph, e_r, e_p, e_t);
                if (code != 4) $fatal(1, "vector file ended inside set %0d", n_sets);

                in_valid <= 1'b1;
                @(posedge clk);
                in_valid <= 1'b0;
                cycles = 0;
                while (!out_valid) begin @(posedge clk); cycles++; end
                if (cycles > worst_cycles) worst_cycles = cycles;
                cyc_total += cycles;
                if (n_sets <= MAXSET && i < MAXSAM) begin
                    cyc[n_sets-1][i] = cycles;
                    set_n[n_sets-1]  = i + 1;
                end
                n_samples++;

                if ($signed(ramp) !== e_r || $signed(pulse) !== e_p || $signed(triang) !== e_t) begin
                    n_fail++;
                    if (n_fail <= maxfail)
                        $display("MISMATCH set %0d sample %0d (phase %0d):\n  ramp  model %0d rtl %0d\n  pulse model %0d rtl %0d\n  triang   model %0d rtl %0d",
                                 n_sets, i, e_ph, e_r, $signed(ramp), e_p, $signed(pulse),
                                 e_t, $signed(triang));
                end
                @(posedge clk);
            end
        end
        $fclose(fd);

        $display("cem3394_vco: %0d settings, %0d samples, %0d mismatches, worst %0d cycles/sample",
                 n_sets, n_samples, n_fail, worst_cycles);
        report_budget();
        if (n_samples == 0) $fatal(1, "no vectors were run");
        if (n_fail == 0) $display("PASS bit-exact against scripts/cem3394_model.py");
        else             $display("FAIL %0d of %0d samples differ", n_fail, n_samples);
        $finish;
    end

endmodule
