// SPDX-License-Identifier: GPL-3.0-or-later
//
// The clock of the 6VB's calibration flip-flop: MAME's counter-0 timer
// (sente6vb.cpp update_counter_0_timer), which is a MODEL of an analog path,
// not a transcription of one (docs/MAME_KLUDGES.md). Of the voices whose final
// gain is above 0.1, the highest frequency wins, and a voice with filter
// resonance above 3 contributes its filter frequency instead of its
// oscillator's. The timer is armed when counter 0's gate rises, re-armed from
// zero by every chip_select_w while it runs, and cancelled when the gate falls.
//
// This is the whole of the voices a silent core needs: the 6VB program measures
// them at boot, and the main board waits for it to finish (docs/HARDWARE_NOTES.md,
// "The ACIA is not optional"). The audio path is Phase 3.
//
// The thresholds are MAME's, on the 12-bit DAC code, cv = dac/512 - 4:
//   final gain > 0.1       compute_db_volume(cv) > 0.1  <=>  cv > 2.5    dac > 3328
//   filter resonance > 3   4 * cv / 2.5 > 3             <=>  cv > 1.875  dac > 3008
// and the frequency is a table read and a shift (scripts/gen_c0_steptab.py).
//
// TIMING. MAME re-arms in zero time. Here a re-arm starts a fixed SCAN-cycle
// search over the six voices and then loads the accumulator with SCAN steps
// already counted, so every tick lands on the cycle it would have with an
// instant re-arm. Nothing the Z80 does can land inside the scan: its I/O
// writes are microseconds apart.

module sente6vb_c0timer (
    input  logic        clk,
    input  logic        rst_n,

    // From sente6vb_io.
    input  logic        cv_valid,
    input  logic [5:0]  cv_mask,
    input  logic [2:0]  cv_reg,
    input  logic [11:0] cv_dac,
    input  logic        ctrl_gate,
    input  logic        cs_update,

    output logic        tick            // one cycle per period
);

    localparam int SCAN = 16;           // re-arm latency; the preload is step << 4
    localparam int ACC  = 44;           // 2^44 is one period (gen_c0_steptab.py)

    // ------------------------------------------------ the control voltages
    // cem3394 device_reset sets every CV to 0 V, DAC code 2048.
    logic [11:0] vco  [0:5];
    logic [11:0] gain [0:5];
    logic [11:0] res  [0:5];
    logic [11:0] filt [0:5];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < 6; i++) begin
                vco[i] <= 12'd2048; gain[i] <= 12'd2048;
                res[i] <= 12'd2048; filt[i] <= 12'd2048;
            end
        end else if (cv_valid) begin
            for (int i = 0; i < 6; i++) if (cv_mask[i]) begin
                case (cv_reg)
                    3'd0: vco[i]  <= cv_dac;
                    3'd1: gain[i] <= cv_dac;
                    3'd2: res[i]  <= cv_dac;
                    3'd3: filt[i] <= cv_dac;
                    default: ;
                endcase
            end
        end
    end

    // ------------------------------------------------------- one voice's step
    // Stage A reads voice `sv`'s registers into a table address; stage B, a
    // cycle later, has the mantissa and shifts it.
    logic [2:0]  sv;
    wire         aud_a = gain[sv] > 12'd3328;
    wire         typ_a = res[sv]  > 12'd3008;
    wire [12:0]  x_a   = typ_a ? {filt[sv], 1'b0} : {1'b0, vco[sv]};

    // x = 384 q + r without a divide: q counts the multiples of 384 at or below x.
    logic [4:0]  q_a;
    logic [12:0] r_a;
    always_comb begin
        q_a = '0;
        for (int k = 1; k <= 21; k++)
            if (x_a >= 13'(384 * k)) q_a = 5'(k);
        r_a = x_a - {q_a, 8'b0} - {1'b0, q_a, 7'b0};
    end

    logic [23:0] mant;
    sente6vb_steptab u_tab (.clk(clk), .addr({typ_a, r_a[8:0]}), .q(mant));

    logic        aud_b, typ_b, val_a, val_b;
    logic [4:0]  q_b;
    wire  [ACC-1:0] step_b = {mant, 16'b0} >> (q_b + (typ_b ? 5'd0 : 5'd7));

    // ------------------------------------------------------------- control
    logic        gate_d;
    logic        armed;                 // MAME's m_counter_0_timer_active
    logic        running;               // the accumulator is counting
    logic [4:0]  sc;                    // scan cycle, 0 = idle
    logic [ACC-1:0] best, step;
    logic [ACC-1:0] acc;

    wire gate_rise = ctrl_gate && !gate_d;
    wire gate_fall = !ctrl_gate && gate_d;
    wire rearm     = (gate_rise && !armed) || (cs_update && armed);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gate_d <= 1'b0; armed <= 1'b0; running <= 1'b0; sc <= '0;
            sv <= '0; val_a <= 1'b0; val_b <= 1'b0;
            aud_b <= 1'b0; typ_b <= 1'b0; q_b <= '0;
            best <= '0; step <= '0; acc <= '0; tick <= 1'b0;
        end else begin
            gate_d <= ctrl_gate;
            tick   <= 1'b0;

            // The pipeline, fed while the scan issues voices 0-5.
            val_b <= val_a;
            aud_b <= aud_a; typ_b <= typ_a; q_b <= q_a;
            if (val_b && aud_b && step_b > best) best <= step_b;

            if (gate_fall && armed) begin
                armed <= 1'b0; running <= 1'b0; sc <= '0; val_a <= 1'b0;
            end else if (rearm) begin
                // Armed for now: whether any voice is audible is known at the
                // end of the scan, and nothing can ask before then.
                armed <= 1'b1; running <= 1'b0; sc <= 5'd1;
                best <= '0; sv <= '0; val_a <= 1'b0;
            end else if (sc != 0) begin
                sc    <= (sc == 5'(SCAN)) ? 5'd0 : sc + 5'd1;
                // cv_valid arrives with cs_update, so the registers are current
                // from sc 1 on.
                val_a <= (sc <= 5'd6);
                sv    <= (sc <= 5'd6) ? 3'(sc - 5'd1) : sv;
                if (sc == 5'(SCAN)) begin
                    if (best != 0) begin
                        running <= 1'b1;
                        step    <= best;
                        acc     <= best << 4;               // SCAN steps
                    end else begin
                        armed <= 1'b0;
                    end
                end
            end else if (running) begin
                // A carry is a tick, reported on the cycle it happens.
                {tick, acc} <= {1'b0, acc} + {1'b0, step};
            end
        end
    end

endmodule
