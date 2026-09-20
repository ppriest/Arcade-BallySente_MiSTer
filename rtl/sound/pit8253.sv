// SPDX-License-Identifier: GPL-3.0-or-later
//
// Intel 8253 programmable interval timer, three counters.
//
// ONLY WHAT THE 6VB USES IS IMPLEMENTED, and the boot trace says exactly what
// that is (docs/CEM3394_SPIKE.md, "Result 6"): control words 0x32, 0x70, 0xB0,
// i.e. counter 0 in **mode 1** and counters 1 and 2 in **mode 0**, all three
// with RW = 11 (LSB then MSB) and binary counting. Modes 2 to 5, BCD, and the
// latch command are NOT implemented; a write selecting one asserts
// `unsupported` so a bench or a probe can catch it rather than have the counter
// quietly do something else. Any game that needs them is a HACKS.md entry.
//
// This is a transcription of MAME's pit8253.cpp phase machine, not of the
// datasheet, because the calibration routine depends on details the datasheet
// does not state and MAME is the reference. The parts that matter, all of them
// confirmed against debug/sente6vb_io-boot:
//
//   * A counter advances on the FALLING edge of its clock input
//     (set_clock_signal_deferred: `if (m_clock_signal && !state) simulate(1)`).
//   * GATE is sampled on the RISING edge of the clock input, and a gate rise
//     arriving between clock edges is REMEMBERED and applied at the next rising
//     edge -- so a mode-1 one-shot does not start when the gate rises. It arms
//     one clock rising edge later and pulls OUT low on the falling edge after
//     that. The 6VB's calibration depends on this: the flip-flop that clocks
//     counter 0 is cleared and preset by register writes, and which of those
//     writes produces an edge decides which oscillator period gets measured.
//   * That deferral applies only to a counter whose clock is a signal. One with
//     a free-running clock (MAME's set_clk, m_clockin != 0) takes the gate at
//     once and loads its count on the write rather than on the next clock.
//     SIGNAL_CLK says which is which.
//
// phase, per MAME:            mode 0                    mode 1
//   0   control word written  OUT low, idle             OUT high, idle
//   1   armed                 load on next clock        load on next clock
//   2   counting              OUT low                   OUT low
//   3   terminal count        OUT high, keeps counting  OUT high, keeps counting
//
// In phase 3 the counter keeps decrementing and wraps through 0xFFFF. The 6VB
// loads counter 1 with 0 and reads it back mid-count, so that wrap is the
// measurement: 0x10000 minus the elapsed 2 MHz ticks.

module pit8253 #(
    // Bit i: counter i's clock is a signal (MAME m_clockin == 0). The 6VB
    // clocks counter 0 from the flip-flop and counters 1 and 2 from 2 MHz.
    parameter logic [2:0] SIGNAL_CLK = 3'b001
) (
    input  logic        clk,           // the host clock; everything is sampled on it
    input  logic        rst_n,

    // Bus: 00-02 select a counter, 03 is the control word register.
    input  logic        cs,            // one cycle per access
    input  logic        wr,            // 1 = write, 0 = read
    input  logic [1:0]  addr,
    input  logic [7:0]  din,
    output logic [7:0]  dout,

    // One clock and gate per counter. These are LEVELS on the host clock, and
    // are edge-detected here, so a caller may drive them from anything.
    input  logic [2:0]  counter_clk,
    input  logic [2:0]  counter_gate,
    output logic [2:0]  counter_out,

    output logic        unsupported    // a mode this module does not implement
);

    logic [15:0] value    [0:2];       // CE, the live counter
    logic [15:0] count    [0:2];       // CR, the value loaded on trigger
    logic [7:0]  lowcount [0:2];       // the LSB of a 16-bit write in progress
    logic [1:0]  phase    [0:2];
    logic [2:0]  mode_is1;
    logic [2:0]  wr_msb;               // RW=11 write phase: 0 = LSB next
    logic [2:0]  rd_msb;
    logic [2:0]  out_r;
    logic [2:0]  gate_r;               // MAME's m_gate: sampled at a clock rise
    logic [2:0]  gate_rose;            // a gate rise waiting for a clock rise
    logic [2:0]  clk_d, gate_d;

    assign counter_out = out_r;

    // A gate rise arriving in the same cycle as a clock rise must be seen by
    // that clock rise: counter_control_w() calls write_gate0() before it touches
    // the flip-flop, so in MAME the gate is always the earlier of the two.
    logic [2:0] gate_rise_now;
    assign gate_rise_now = counter_gate & ~gate_d & mode_is1;

    // The value a read of `addr` would return NOW: the live count, LSB then MSB
    // as RW=11 requires. It is combinational because the caller latches it --
    // see the note on the read pointer in sente6vb_io.sv. Reading the control
    // register is illegal; MAME returns 0 for it.
    always_comb begin
        dout = 8'h00;
        if (addr != 2'd3)
            dout = rd_msb[addr] ? value[addr][15:8] : value[addr][7:0];
    end

    // The gate a counter actually uses: the sampled one when its clock is a
    // signal, the live one when it free-runs.
    function automatic logic eff_gate(input int i);
        return SIGNAL_CLK[i] ? gate_r[i] : counter_gate[i];
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        logic [1:0] sel;
        logic [2:0] mode;

        if (!rst_n) begin
            for (i = 0; i < 3; i++) begin
                value[i] <= '0; count[i] <= '0; lowcount[i] <= '0; phase[i] <= 2'd0;
            end
            mode_is1 <= '0; wr_msb <= '0; rd_msb <= '0;
            out_r <= 3'b111; gate_r <= 3'b111; gate_rose <= '0;
            clk_d <= '0; gate_d <= '0;
            unsupported <= 1'b0;
        end else begin
            clk_d  <= counter_clk;
            gate_d <= counter_gate;

            // --------------------------------------------- gate edges (write)
            // gate_w_deferred: a rise on an edge-sensitive mode is remembered,
            // or acted on at once when the clock free-runs.
            for (i = 0; i < 3; i++) begin
                if (gate_rise_now[i]) begin
                    // Not remembered when this cycle's clock rise consumes it.
                    if (!SIGNAL_CLK[i])                        phase[i]     <= 2'd1;
                    else if (!(counter_clk[i] && !clk_d[i]))   gate_rose[i] <= 1'b1;
                end
            end

            // --------------------------------------------------- clock edges
            for (i = 0; i < 3; i++) begin
                if (counter_clk[i] && !clk_d[i]) begin
                    // Rising: sample the gate, then consume a pending rise.
                    gate_r[i] <= counter_gate[i];
                    if (gate_rose[i] || gate_rise_now[i]) begin
                        if (mode_is1[i]) phase[i] <= 2'd1;
                        gate_rose[i] <= 1'b0;
                    end
                end else if (!counter_clk[i] && clk_d[i]) begin
                    // Falling: simulate(1).
                    if (mode_is1[i]) begin
                        // Mode 1 ignores the gate once armed, and keeps counting
                        // past terminal count.
                        if (phase[i] == 2'd1) begin
                            value[i] <= count[i];
                            out_r[i] <= 1'b0;
                            phase[i] <= 2'd2;
                        end else begin
                            if (phase[i] == 2'd2 && value[i] == 16'd1) begin
                                phase[i] <= 2'd3;
                                out_r[i] <= 1'b1;
                            end
                            value[i] <= value[i] - 16'd1;
                        end
                    end else if (phase[i] != 2'd0) begin
                        if (phase[i] == 2'd1) begin
                            value[i] <= count[i];
                            phase[i] <= 2'd2;
                        end else if (eff_gate(i)) begin
                            // Mode 0 only counts while its gate is high.
                            if (phase[i] == 2'd2 && value[i] == 16'd1) begin
                                phase[i] <= 2'd3;
                                out_r[i] <= 1'b1;
                                value[i] <= 16'd0;
                            end else begin
                                value[i] <= value[i] - 16'd1;
                            end
                        end
                    end
                end
            end

            // ------------------------------------------------ bus, last wins
            // MAME runs update() before applying a write, so a write landing on
            // a clock edge overrides what that edge did.
            if (cs) begin
                if (addr == 2'd3) begin
                    if (wr) begin
                        sel  = din[7:6];
                        // CTRL_MODE: bit 2 set aliases modes 6 and 7 to 2 and 3.
                        mode = din[2] ? {1'b0, din[2:1]} : din[3:1];
                        if (sel == 2'd3 || din[5:4] != 2'b11 || din[0] ||
                            (mode != 3'd0 && mode != 3'd1)) begin
                            // Read-back/latch, a non-RW=11 access, BCD, or a mode
                            // this board never selects.
                            unsupported <= 1'b1;
                        end else begin
                            mode_is1[sel] <= (mode == 3'd1);
                            wr_msb[sel]   <= 1'b0;
                            rd_msb[sel]   <= 1'b0;
                            phase[sel]    <= 2'd0;
                            // Mode 0 takes OUT low on the control word; mode 1
                            // leaves it high until a gate triggers it.
                            out_r[sel]    <= (mode == 3'd1);
                        end
                    end
                end else begin
                    sel = addr;
                    if (wr) begin
                        if (!wr_msb[sel]) begin
                            lowcount[sel] <= din;
                            wr_msb[sel]   <= 1'b1;
                            // Intel says a mode-0 MSB write in phase 2 does not
                            // stop the count; MAME found otherwise, and stops it
                            // on the LSB write.
                            if (!mode_is1[sel]) begin
                                phase[sel] <= 2'd0;
                                out_r[sel] <= 1'b0;
                            end
                        end else begin
                            count[sel]  <= {din, lowcount[sel]};
                            wr_msb[sel] <= 1'b0;
                            // load_count(): only modes 0 and 4 arm on the write.
                            if (!mode_is1[sel]) begin
                                phase[sel] <= 2'd1;
                                // With a free-running clock MAME then calls
                                // simulate(0), which loads CE at once.
                                if (!SIGNAL_CLK[sel]) value[sel] <= {din, lowcount[sel]};
                            end
                        end
                    end else begin
                        rd_msb[sel] <= ~rd_msb[sel];
                    end
                end
            end
        end
    end

endmodule
