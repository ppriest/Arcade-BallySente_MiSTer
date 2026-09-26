// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 0 criterion 5, second half: the 6VB's own self-calibration routine,
// running on T80 out of the audio board's real ROM, against the real 8253, the
// real counter-0 flip-flop and an oscillator at the frequency the CEM3394 model
// says the written control voltage produces.
//
// docs/CEM3394_SPIKE.md "Result 6" decodes what the routine does and predicts
// what it should read:
//
//     counter1 = 0xFFFF - round(count0 * 2e6 / f_vco)
//
// where count0 is what the routine loaded into counter 0: counter 0 is a mode-1
// one-shot, so its OUT stays low for that many flip-flop clocks, and counter 1
// -- gated by OUT through an inverter -- counts 2 MHz ticks for that many
// oscillator periods. The routine raises count0 as the frequency rises, 1 at
// the bottom of the range and 16 at the top, so that a period of a hundred-odd
// ticks is still measured to a useful precision.
//
// This runs it and checks. The values MAME's Z80 read are in
// debug/sente6vb_io-boot/sente6vb_io_boot.trace; the same reads here should
// produce the same numbers.
//
// WHAT IS MODELLED HERE RATHER THAN SYNTHESISED: the control-voltage to
// frequency map. `f = 431.894 * 2^(-cv/0.75)` is evaluated in the bench, in
// real arithmetic, and used to drive the periodic timer that clocks the
// flip-flop. In the core that map becomes a lookup table feeding cem3394_vco's
// `step`, which is not written yet. So this bench proves THE LOOP CLOSES given
// a correct map; the map itself is validated separately, by
// `cem3394_model.py sweep` against the datasheet law to 7e-7.
`timescale 1ns/1ps

module tb_calib;

    import state_image_pkg::*;

    // The 6VB runs at 8 MHz; the Z80 gets every other cycle and the 8253's
    // counters 1 and 2 get one tick in four (sente6vb.cpp:107, :125).
    logic clk = 0;
    always #62.5 clk = ~clk;                 // 8 MHz
    logic rst_n = 0;                         // the board
    logic cpu_rst_n = 0;                     // the CPU, released after the replay

    logic [1:0] div = 0;
    always_ff @(posedge clk) div <= div + 2'd1;
    wire clken     = (div[0] == 1'b0);       // 4 MHz Z80
    wire tick_2mhz = (div == 2'd0);          // 2 MHz counter clock

    // ------------------------------------------------------------------ CPU
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
    wire [15:0] addr;
    wire [7:0]  dout;
    logic [7:0] din;

    T80se #(.Mode(0), .T2Write(0), .IOWait(1)) u_cpu (
        .RESET_n(cpu_rst_n), .CLK_n(clk), .CLKEN(clken),
        .WAIT_n(1'b1), .INT_n(1'b1), .NMI_n(1'b1), .BUSRQ_n(1'b1),
        .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
        .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n),
        .HALT_n(halt_n), .BUSAK_n(busak_n),
        .A(addr), .DI(din), .DO(dout)
    );

    logic [7:0] rom [0:16'h1fff];
    logic [7:0] ram [0:16'h3fff];

    // ------------------------------------------------------------- the board
    logic       io_cs, io_wr;
    logic [7:0] io_dout;
    logic       cv_valid, pit_unsupported;
    logic [2:0] cv_chip, cv_reg;
    logic [11:0] cv_dac;
    logic       ctrl_gate, cs_update;

    logic osc_clk;

    // ------------------------------------------------ starting from an image
    // +state=<manifest> replays the I/O writes MAME had already made, loads its
    // RAM, and hands the CPU a stub that restores its registers and jumps back
    // in. Without it the bench boots from reset as before. See
    // sim/common/state_image.sv for what an image can and cannot carry.
    string      state_file;
    z80_state_t st;
    logic [7:0] stub_q[$];
    logic [7:0] stub [0:255];
    int         stub_len = 0;
    logic       stub_active = 0;

    logic       rep_active = 0, rep_cs = 0;
    logic [7:0] rep_addr, rep_din;

    wire [7:0] io_addr_w = rep_active ? rep_addr : addr[7:0];
    wire [7:0] io_din_w  = rep_active ? rep_din  : dout;

    sente6vb_io u_io (
        .clk(clk), .rst_n(rst_n),
        .io_cs(io_cs), .io_wr(io_wr), .io_addr(io_addr_w), .io_din(io_din_w),
        .io_dout(io_dout),
        .clk_2mhz_tick(tick_2mhz), .osc_clk(osc_clk),
        .cv_valid(cv_valid), .cv_chip(cv_chip), .cv_reg(cv_reg), .cv_dac(cv_dac),
        .ctrl_gate(ctrl_gate), .cs_update(cs_update),
        .pit_unsupported(pit_unsupported)
    );

    // A single I/O access pulse, on the clk_en edge where IORQ is asserted.
    logic iorq_d;
    always_ff @(posedge clk) if (clken) iorq_d <= iorq_n;
    assign io_cs = rep_active ? rep_cs : (clken && !iorq_n && iorq_d && m1_n);
    assign io_wr = rep_active ? 1'b1   : !wr_n;

    // I/O FIRST. On a Z80 `IN A,(n)` the port is addr[7:0] and the accumulator
    // sits in addr[15:8], so an I/O read to port 0x08 with a small A looks like
    // an address inside ROM. Decoding memory first returns ROM bytes for every
    // counter-state poll, and the calibration routine spins forever.
    always_comb begin
        if (!iorq_n)                                   din = io_dout;
        else if (stub_active && addr < stub_len)       din = stub[addr];
        else if (addr <= 16'h1fff)                     din = rom[addr];
        else if (addr >= 16'h2000 && addr <= 16'h5fff) din = ram[addr - 16'h2000];
        else                                           din = 8'h00;
    end

    // The stub is straight-line, so it is finished once its last byte -- the
    // high half of the JP target -- has been fetched.
    always_ff @(posedge clk) if (clken)
        if (stub_active && !mreq_n && iorq_n && rfsh_n && !rd_n && addr == stub_len - 1)
            stub_active <= 1'b0;

    always_ff @(posedge clk) if (clken)
        if (!mreq_n && iorq_n && rfsh_n && !wr_n && addr >= 16'h2000 && addr <= 16'h5fff)
            ram[addr - 16'h2000] <= dout;

    // ------------------------------------------- the oscillator the FF sees
    // sente6vb.cpp update_counter_0_timer() decides this, and it is a MODEL of
    // an analog board, not a transcription of one: only voices whose final gain
    // exceeds 0.1 clock the flip-flop, at the HIGHEST of their frequencies, and
    // a voice with high filter resonance contributes its filter frequency
    // instead of its oscillator frequency. The real wiring is not in the driver;
    // see docs/MAME_KLUDGES.md. Reproduced here because the point of this bench
    // is to compare against MAME.
    //
    // It is a PERIODIC TIMER, not a free-running oscillator, and when it fires
    // the flip-flop takes the control register's D bit -- so a constant D gives
    // no edges at all. It is armed when counter 0's gate rises, restarted from
    // zero by every chip_select_w while it runs, and cancelled when the gate
    // falls. All three matter: the calibration measures the interval between
    // two consecutive firings, and the writes that bracket it must not restart
    // the timer or the measurement would be short.
    //
    // Register numbers are chip_select_w()'s: 0 VCO freq, 1 final gain,
    // 2 filter resonance, 3 filter frequency.
    real vco_cv [0:5];
    real gain_cv[0:5];
    real res_cv [0:5];
    real filt_cv[0:5];

    real         cv, freq;
    bit          timer_active = 0;
    bit          gate_d = 0;
    longint      step_q = 0;
    logic [32:0] acc = 0;
    bit          osc_tick = 0;
    assign osc_clk = osc_tick;

    // compute_db_volume(cv) > 0.1 reduces to cv > 2.5: between 2.5 V and 4 V the
    // datasheet law is linear from 20 dB to 0, and 0.891251^20 is exactly 0.1.
    function automatic bit audible(input real gcv);
        return gcv > 2.5;
    endfunction

    always @(posedge clk) begin
        real best, f_i;
        bit  reload;
        int  i;

        reload = 1'b0;

        if (cv_valid) begin
            cv = real'(cv_dac) * (8.0 / 4096.0) - 4.0;
            case (cv_reg)
                3'd0: vco_cv [cv_chip] = cv;
                3'd1: gain_cv[cv_chip] = cv;
                3'd2: res_cv [cv_chip] = cv;
                3'd3: filt_cv[cv_chip] = cv;
                default: ;
            endcase
        end

        if (ctrl_gate && !gate_d && !timer_active) reload = 1'b1;
        if (!ctrl_gate && gate_d)                  timer_active = 1'b0;
        gate_d = ctrl_gate;

        if (cs_update && timer_active) reload = 1'b1;

        if (reload) begin
            best = 0.0;
            for (i = 0; i < 6; i++) begin
                if (audible(gain_cv[i])) begin
                    // filt_res = 4*cv/2.5, so filt_res > 3 is cv > 1.875.
                    if (res_cv[i] > 1.875)
                        f_i = 1303.0303 * (2.0 ** (-filt_cv[i] / 0.375));
                    else
                        f_i = 431.894 * (2.0 ** (-vco_cv[i] / 0.75));
                    if (f_i > best) best = f_i;
                end
            end
            freq = best;
            if (best > 0.0) begin
                timer_active = 1'b1;
                step_q = longint'(best / 8.0e6 * 4294967296.0 + 0.5);
                acc    = '0;
            end else begin
                timer_active = 1'b0;
                step_q = 0;
            end
        end

        // One tick per period: the accumulator carries out after 8e6/freq
        // cycles of the 8 MHz clock.
        osc_tick = 1'b0;
        if (timer_active) begin
            acc      = {1'b0, acc[31:0]} + step_q;
            osc_tick = acc[32];
        end
    end

    // ---------------------------------------------------- observe the reads
    // Counter 1 is read LSB then MSB at ports 0x01; pair them up.
    // Every I/O access, in MAME's trace format, so a divergence can be located
    // with scripts/classify_trace_diff.py rather than guessed at.
    int io_fd, io_n = 0;

    // The replay is not logged: those accesses are MAME's, already counted in
    // the image's io_seq, and io_n is started from it so the numbering lines up.
    // One cycle behind io_cs, because sente6vb_io LATCHES its read data there:
    // logging at io_cs would record the PREVIOUS access's value. Writes are
    // delayed with it so the trace stays in order.
    logic       io_cs_d, io_wr_d, rep_active_d;
    logic [7:0] io_addr_d, io_din_d;
    always_ff @(posedge clk) begin
        io_cs_d      <= io_cs;
        io_wr_d      <= io_wr;
        io_addr_d    <= io_addr_w;
        io_din_d     <= io_din_w;
        rep_active_d <= rep_active;
    end

    // io_cs already carries the CPU's clock enable, so these are not gated
    // again: the replay drives io_cs on its own cadence.
    always_ff @(posedge clk) begin
        if (io_cs_d && !rep_active_d) begin
            io_n++;
            if (io_wr_d) $fwrite(io_fd, "%0d	w	%02X	FF	%02X
", io_n, io_addr_d, io_din_d);
            else         $fwrite(io_fd, "%0d	r	%02X	FF	%02X
", io_n, io_addr_d, io_dout);
        end
    end

    // Program-space trace too: sim/sound_cpu_tb already matched MAME's for
    // 60,000 accesses, so diffing this one against the same reference says
    // whether the divergence is in the CPU or in this bench's board.
    int pr_fd, pr_n = 0, pr_max;
    logic pr_seen;
    always_ff @(posedge clk) begin
        if (!cpu_rst_n) pr_seen <= 1'b0;
        else if (clken) begin
            if (!mreq_n && iorq_n && rfsh_n && (!rd_n || !wr_n) && !stub_active) begin
                if (!pr_seen) begin
                    pr_seen <= 1'b1;
                    pr_n++;
                    if (pr_n <= pr_max) begin
                        if (!wr_n) $fwrite(pr_fd, "%0d	w	%04X	FF	%02X
", pr_n, addr, dout);
                        else       $fwrite(pr_fd, "%0d	r	%04X	FF	%02X
", pr_n, addr, din);
                    end
                end
            end else pr_seen <= 1'b0;
        end
    end

    int      n_meas = 0, n_bad = 0;
    logic    have_lsb = 0;
    logic [7:0] lsb;
    longint  predicted;

    // Counter 0's count, which decides how many oscillator periods the routine
    // measures at a time. It rises with the frequency: 1 at the bottom of the
    // range, 16 at the top. Tracked through the replay too, so an image taken
    // mid-calibration starts with the right one.
    logic [15:0] count0 = 16'd1;
    logic        c0_msb = 1'b0;
    logic [7:0]  c0_lsb;
    always_ff @(posedge clk) begin
        if (io_cs && io_wr && io_addr_w == 8'h00) begin
            c0_msb <= ~c0_msb;
            if (!c0_msb) c0_lsb <= io_din_w;
            else         count0 <= {io_din_w, c0_lsb};
        end
    end

    always_ff @(posedge clk) begin
        if (io_cs_d && !io_wr_d && io_addr_d == 8'h01) begin
            if (!have_lsb) begin
                lsb <= io_dout;
                have_lsb <= 1'b1;
            end else begin
                automatic longint got = {io_dout, lsb};
                have_lsb <= 1'b0;
                n_meas++;
                // Round the WHOLE window, not one period then multiply: at the
                // high end a period is under 140 ticks and count0 reaches 16,
                // so a rounded period would be up to eight counts out.
                predicted = (freq > 0.0)
                          ? 65535 - longint'(real'(count0) * 2.0e6 / freq + 0.5)
                          : 65535;
                // Three counts of 65,535 is the tolerance Result 6 measured
                // between MAME's own readings and the formula.
                if (got > predicted + 3 || got < predicted - 3) begin
                    n_bad++;
                    if (n_bad <= 10)
                        $display("MEAS %0d: cv %.3f V, f %.3f Hz -> predicted %0d, read %0d (delta %0d)",
                                 n_meas, cv, freq, predicted, got, got - predicted);
                end else if (n_meas <= 8) begin
                    $display("MEAS %0d: cv %.3f V, f %8.3f Hz -> predicted %0d, read %0d  OK",
                             n_meas, cv, freq, predicted, got);
                end
            end
        end
    end

    // Load an image: RAM, then the I/O writes that preceded it (one per clock,
    // driven straight at sente6vb_io in place of the CPU), then the register
    // stub. The replay rebuilds the board's programmable state; what it cannot
    // rebuild is anything that depended on the time between those writes, which
    // is why the image is taken where the routine reprograms what it uses.
    task automatic load_state(input string path);
        int    fd, code, n;
        string line, ramp;
        logic [31:0] port, data;

        st = si_read_z80(path);
        $display("STATE %s: PC=%04X SP=%04X io_seq=%0d, %0d I/O writes",
                 path, st.pc, st.sp, st.io_seq, st.iow_n);

        ramp = {st.dir, "/", st.ram_file};
        $readmemh(ramp, ram);
        if (st.ram_lo != 16'h2000)
            $fatal(1, "%s starts at %04X; this bench's RAM starts at 2000",
                   st.ram_file, st.ram_lo);

        fd = $fopen({st.dir, "/", st.iow_file}, "r");
        if (fd == 0) $fatal(1, "no I/O write log at %s/%s", st.dir, st.iow_file);
        n = 0;
        rep_active = 1'b1;
        while (!$feof(fd)) begin
            line = "";
            void'($fgets(line, fd));
            if (line.len() == 0 || line.getc(0) == "#") continue;
            if ($sscanf(line, "%h %h", port, data) != 2) continue;
            @(posedge clk);
            rep_addr = port[7:0];
            rep_din  = data[7:0];
            rep_cs   = 1'b1;
            @(posedge clk);
            rep_cs   = 1'b0;
            n++;
        end
        $fclose(fd);
        @(posedge clk);
        rep_active = 1'b0;
        if (n != st.iow_n)
            $display("NOTE  replayed %0d writes, manifest says %0d", n, st.iow_n);

        si_z80_stub(st, stub_q);
        stub_len = stub_q.size();
        if (st.pc < stub_len)
            $fatal(1, "the image's PC %04X is inside the %0d-byte stub", st.pc, stub_len);
        foreach (stub_q[i]) stub[i] = stub_q[i];
        stub_active = 1'b1;

        io_n = st.io_seq;
        $fwrite(io_fd, "# resumed from a state image at MAME I/O access %0d
", st.io_seq);
    endtask

    int maxcycles;
    initial begin
        if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 16000000;   // 2 s: calibration starts at 0.5 s
        foreach (rom[i]) rom[i] = 8'h00;
        foreach (ram[i]) ram[i] = 8'h00;
        if (!$value$plusargs("prmax=%d", pr_max)) pr_max = 60000;
        pr_fd = $fopen("debug/sente6vb-boot/sente6vb_rtl.trace", "w");
        $fwrite(pr_fd, "# RTL 6VB sound-CPU bus accesses from reset, in order.
");
        $fwrite(pr_fd, "# seq	rw	addr	mask	data
");
        io_fd = $fopen("debug/sente6vb_io-boot/sente6vb_io_rtl.trace", "w");
        $fwrite(io_fd, "# RTL 6VB sound-CPU I/O accesses from reset, in order.
");
        $fwrite(io_fd, "# seq	rw	addr	mask	data
");
        $readmemh("debug/rom/sente6vb_audiocpu.hex", rom);
        if (rom[0] !== 8'hed) $fatal(1, "ROM did not load -- run from the repository root");
        // Everything starts silent, as it does on the board: no voice is
        // audible until the program writes a gain, so the flip-flop is not
        // clocked and step_q stays zero.
        for (int i = 0; i < 6; i++) begin
            vco_cv[i] = 0.0; gain_cv[i] = -4.0; res_cv[i] = 0.0; filt_cv[i] = 0.0;
        end
        cv = 0.0; freq = 0.0; step_q = 0;

        repeat (20) @(posedge clk);
        rst_n = 1;                       // the board first: the replay drives it

        if ($value$plusargs("state=%s", state_file)) begin
            load_state(state_file);
        end else begin
            stub_active = 1'b0;
        end

        repeat (20) @(posedge clk);
        cpu_rst_n = 1;

        repeat (maxcycles) @(posedge clk);

        $display("\ncalibration: %0d counter-1 measurements, %0d outside tolerance",
                 n_meas, n_bad);
        if (pit_unsupported)
            $display("NOTE the 8253 saw a mode this module does not implement");
        if (n_meas == 0)
            $display("FAIL the routine never read counter 1 -- the loop did not run");
        else if (n_bad == 0)
            $display("PASS every measurement matches 0xFFFF - 2e6/f_vco");
        else
            $display("FAIL %0d of %0d measurements are outside tolerance", n_bad, n_meas);
        $finish;
    end

endmodule
