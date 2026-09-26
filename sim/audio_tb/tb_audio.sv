// SPDX-License-Identifier: GPL-3.0-or-later
//
// The 6VB's audio, rtl/sound/sente6vb_audio.sv behind the real port decode
// (sente6vb_io), against scripts/sente6vb_audio.py sample for sample.
//
//   python scripts/sente6vb_audio.py vectors cshift --secs 11
//   scripts/run_verilator.sh audio_tb
//
// The vectors are MAME's recorded 6VB port writes, grouped by the sample they
// precede, and the 16-bit output the specification computes. Each sample: the
// writes go in through sente6vb_io one I/O access at a time, the parameter unit
// is let finish, the tick is given, and the output is compared when it comes.
// Ticks are spaced by the bench rather than a clock, so the comparison does not
// depend on how many cycles a write takes.
//
//   +realtime=1   ticks at 96 kHz from the 40 MHz clock, as sente6vb makes them,
//                 and no comparison: writes cannot then be aligned to samples.
//                 What it measures is whether the stages keep up -- `late`
//                 counts ticks that found the previous sample's voices unlaunched.
`timescale 1ns/1ps

module tb_audio;

    logic clk = 0;
    always #12.5 clk = ~clk;
    logic rst_n = 0;

    // ----------------------------------------------------------- the ports
    logic        io_cs = 0, io_wr = 1;
    logic [7:0]  io_addr, io_din, io_dout;
    logic        cv_valid, ctrl_gate, cs_update, pit_unsupported;
    logic [2:0]  cv_chip, cv_reg, pit_out;
    logic [5:0]  cv_mask, counter_control;
    logic [11:0] cv_dac;

    sente6vb_io u_io (
        .clk(clk), .rst_n(rst_n),
        .io_cs(io_cs), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
        .clk_2mhz_tick(1'b0), .osc_clk(1'b0),
        .cv_valid(cv_valid), .cv_chip(cv_chip), .cv_reg(cv_reg), .cv_dac(cv_dac),
        .cv_mask(cv_mask), .ctrl_gate(ctrl_gate), .cs_update(cs_update),
        .counter_control(counter_control), .pit_out(pit_out),
        .pit_unsupported(pit_unsupported)
    );

    logic        tick = 0, svalid;
    logic signed [15:0] s;
    logic [7:0]  late, povr;

    sente6vb_audio dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(rt_mode != 0 ? rtick : tick),
        .cv_valid(cv_valid), .cv_mask(cv_mask), .cv_reg(cv_reg), .cv_dac(cv_dac),
        .audio_en(counter_control[0]),
        .sample(s), .sample_valid(svalid), .late(late), .param_overrun(povr)
    );

    int fd, n = 0, n_bad = 0, n_w = 0, port, data, want, nz = 0, worst = 0, cyc;
    string line;

    string vec;
    int    rt_mode = 0;
    logic [31:0] racc = 0;
    logic        rtick;
    always_ff @(posedge clk) if (rt_mode != 0) {rtick, racc} <= {1'b0, racc} + 33'd10307922;

    initial begin
        if (!$value$plusargs("vec=%s", vec)) vec = "debug/cem3394/audio_vectors.txt";
        void'($value$plusargs("realtime=%d", rt_mode));
        fd = $fopen(vec, "r");
        if (fd == 0) $fatal(1, "no vectors -- run scripts/sente6vb_audio.py vectors");
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);
        while (!$feof(fd)) begin
            line = "";
            void'($fgets(line, fd));
            if (line.len() == 0 || line.getc(0) == "#") continue;
            if (line.getc(0) == "W") begin
                void'($sscanf(line, "W %d %d", port, data));
                @(posedge clk);
                io_cs <= 1'b1; io_wr <= 1'b1; io_addr <= 8'(port); io_din <= 8'(data);
                @(posedge clk);
                io_cs <= 1'b0;
                repeat (2) @(posedge clk);
                while (dut.u_params.busy) @(posedge clk);
                n_w++;
            end else begin
                void'($sscanf(line, "S %d", want));
                if (rt_mode != 0) begin
                    while (!svalid) @(posedge clk);
                    @(posedge clk);
                    if (s != 0) nz++;
                    n++;
                    continue;
                end
                @(posedge clk);
                tick <= 1'b1;
                @(posedge clk);
                tick <= 1'b0;
                cyc = 1;
                while (!svalid) begin @(posedge clk); cyc++; end
                if (cyc > worst) worst = cyc;
                if (s != 16'(want)) begin
                    n_bad++;
                    if (n_bad <= 10)
                        $display("MISMATCH sample %0d (%.4f s): got %0d want %0d", n, n / 96000.0, s, want);
                end
                if (want != 0) nz++;
                n++;
                if (n % 96000 == 0) $display("  %0d s", n / 96000);
            end
        end
        $display("audio_tb: %0d samples (%0d non-zero), %0d writes, %0d mismatches",
                 n, nz, n_w, n_bad);
        $display("  worst tick-to-output %0d cycles, %0d late ticks, %0d parameter overruns",
                 worst, late, povr);
        if (n_bad == 0) $display("PASS bit-exact against scripts/sente6vb_audio.py");
        else            $display("FAIL");
        $finish;
    end

endmodule
