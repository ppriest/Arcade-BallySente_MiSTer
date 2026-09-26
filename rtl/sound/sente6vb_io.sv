// SPDX-License-Identifier: GPL-3.0-or-later
//
// The 6VB audio board's I/O decode: the 8253, the CEM3394 control path, and the
// flip-flop that feeds counter 0. From sente6vb.cpp's io_map (global mask 0xff):
//
//   00-03  8253
//   08-0F  read : bit 1 counter 0 OUT, bit 0 the INVERSE of the flip-flop
//   08-09  write: counter control -- bit 5 NMI enable, bit 4 FF clear (low),
//                 bit 3 FF D input, bit 2 FF preset (low), bit 1 counter 0 GATE,
//                 bit 0 audio enable
//   0A     write: DAC data, upper 6 bits      0B  write: DAC data, lower 6
//   0C-0D  write: CEM3394 register select (3 bits)
//   0E-0F  write: CEM3394 chip enable, one bit per chip
//
// The control path is a latch-on-rising-edge: chip_select_w() acts on the bits
// that GO HIGH, and a DAC write while any chip is already selected re-latches by
// toggling the select off and back on. Reproduced here exactly, because the
// calibration routine drives it thousands of times per boot.
//
// The flip-flop is the heart of the self-calibration. Its clock is a voice
// oscillator; it passes the control register's D bit through on each edge, and
// its inverse clocks counter 0. Counter 0's OUT gates counter 1 through an
// inverter, so counter 1 -- running at 2 MHz -- measures one oscillator period.
// See docs/CEM3394_SPIKE.md, "Result 6", for the arithmetic that falls out.
//
// CLEAR and PRESET are EVENTS, not levels. set_counter_0_ff() is called from
// counter_control_w() on the write, so a clock edge arriving while the clear
// bit is still low still clocks D through. Holding the flip-flop cleared
// instead would stall the calibration loop.

module sente6vb_io (
    input  logic        clk,
    input  logic        rst_n,

    // Z80 I/O port access, one cycle per access.
    input  logic        io_cs,
    input  logic        io_wr,
    input  logic [7:0]  io_addr,
    input  logic [7:0]  io_din,
    output logic [7:0]  io_dout,

    input  logic        clk_2mhz_tick,  // one cycle high at 2 MHz
    input  logic        osc_clk,        // the voice oscillator clocking the FF

    // The latched control voltage, for whichever chip and register was selected.
    output logic        cv_valid,
    output logic [2:0]  cv_chip,
    output logic [2:0]  cv_reg,
    output logic [11:0] cv_dac,
    output logic [5:0]  cv_mask,        // every chip the latch reaches

    // What drives counter 0's flip-flop timer in MAME: its gate, and a pulse on
    // every chip_select_w -- each of which calls update_counter_0_timer() and so
    // restarts the timer from zero.
    output logic        ctrl_gate,
    output logic        cs_update,

    output logic [5:0]  counter_control, // bit 5 NMI enable, bit 0 audio enable
    output logic [2:0]  pit_out,         // OUT 2 is the Z80's IRQ

    output logic        pit_unsupported
);

    // ------------------------------------------------------------- registers
    logic [11:0] dac_value;
    logic [2:0]  dac_register;
    logic [5:0]  chip_select;

    // counter_control_w() acts on the gate before it touches the flip-flop, so
    // the gate has to reach the 8253 on the same cycle the flip-flop moves --
    // one cycle later and a clock edge produced by the same write would sample
    // the old gate. Hence the bypass rather than the registered bit.
    wire ctrl_wr = io_cs && io_wr && (io_addr[7:1] == 7'b0000_100);
    assign ctrl_gate = ctrl_wr ? io_din[1] : counter_control[1];

    // ------------------------------------------------------- the flip-flop
    logic ff_q, osc_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ff_q <= 1'b0; osc_d <= 1'b0;
        end else begin
            osc_d <= osc_clk;
            // counter_control_w: clear wins over preset, and both act once.
            if (ctrl_wr) begin
                if (!io_din[4])      ff_q <= 1'b0;
                else if (!io_din[2]) ff_q <= 1'b1;
            end else if (osc_clk && !osc_d) begin
                ff_q <= counter_control[3];
            end
        end
    end

    // --------------------------------------------------------------- 8253
    logic        pit_cs;
    logic [7:0]  pit_dout;

    // Counter 0 is clocked by the INVERSE of the flip-flop, counters 1 and 2 by
    // 2 MHz. Counter 0's OUT gates counter 1 through an inverter.
    pit8253 #(.SIGNAL_CLK(3'b001)) u_pit (
        .clk(clk), .rst_n(rst_n),
        .cs(pit_cs), .wr(io_wr), .addr(io_addr[1:0]), .din(io_din), .dout(pit_dout),
        .counter_clk ({clk_2mhz_tick, clk_2mhz_tick, ~ff_q}),
        .counter_gate({1'b1, ~pit_out[0], ctrl_gate}),
        .counter_out (pit_out),
        .unsupported (pit_unsupported)
    );

    assign pit_cs = io_cs && (io_addr[7:2] == 6'd0);

    // ---------------------------------------------------------------- reads
    // io_dout is LATCHED at io_cs and held until the next access, and that is
    // load-bearing rather than tidiness. The 8253's read pointer advances on
    // each read, so a combinational read value CHANGES one cycle into the
    // access -- and a Z80 samples its data bus at the END of an I/O cycle, two
    // clock enables after io_cs. Driven combinationally, the CPU took counter
    // 1's high byte for its low byte and the calibration compared a measurement
    // against a target with the halves swapped: the bus trace showed the right
    // bytes in the right order and the CPU had read them in the wrong one.
    //
    // Latching also fixes the instant a read is taken at, for the ports whose
    // value moves on its own (08-0F carry the flip-flop and counter 0's OUT).
    // It is the start of the access here, which is the instant MAME reads at.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            io_dout <= 8'hff;
        else if (io_cs && !io_wr) begin
            if (io_addr[7:2] == 6'd0)
                io_dout <= pit_dout;
            else if (io_addr[7:3] == 5'b00001)      // 08-0F
                io_dout <= {6'b0, pit_out[0], ~ff_q};
            else
                io_dout <= 8'hff;
        end
    end

    // --------------------------------------------------------------- writes
    always_ff @(posedge clk or negedge rst_n) begin
        logic [5:0] rising;

        if (!rst_n) begin
            dac_value <= '0; dac_register <= '0;
            chip_select <= 6'h3f; counter_control <= '0;
            cv_valid <= 1'b0; cv_chip <= '0; cv_reg <= '0; cv_dac <= '0;
            cv_mask <= '0;
            cs_update <= 1'b0;
        end else begin
            cv_valid  <= 1'b0;
            cs_update <= 1'b0;

            if (io_cs && io_wr) begin
                if (io_addr[7:1] == 7'b0000_100)            // 08-09
                    counter_control <= io_din[5:0];

                if (io_addr[7:1] == 7'b0000_101) begin      // 0A-0B, the DAC
                    if (io_addr[0]) dac_value <= {dac_value[11:6], io_din[7:2]};
                    else            dac_value <= {io_din[5:0], dac_value[5:0]};
                    // A DAC write with a chip already selected re-latches, which
                    // the driver does by pulsing the select off and back on --
                    // two chip_select_w calls, so two timer restarts.
                    if (chip_select != 6'h3f) begin
                        cv_valid  <= 1'b1;
                        cs_update <= 1'b1;
                        cv_chip   <= sel_first(~chip_select);
                        cv_mask   <= ~chip_select;
                        cv_reg    <= dac_register;
                        cv_dac    <= io_addr[0] ? {dac_value[11:6], io_din[7:2]}
                                                : {io_din[5:0], dac_value[5:0]};
                    end
                end

                if (io_addr[7:1] == 7'b0000_110)            // 0C-0D
                    dac_register <= io_din[2:0];

                if (io_addr[7:1] == 7'b0000_111) begin      // 0E-0F, chip enable
                    rising = io_din[5:0] & ~chip_select;
                    chip_select <= io_din[5:0];
                    cs_update   <= 1'b1;
                    if (|rising) begin
                        cv_valid <= 1'b1;
                        cv_chip  <= sel_first(rising);
                        cv_mask  <= rising;
                        cv_reg   <= dac_register;
                        cv_dac   <= dac_value;
                    end
                end
            end
        end
    end

    // The lowest set bit, as a chip index, for sim/calib_tb's single-voice
    // model. cv_mask carries every chip, as chip_select_w() acts on them.
    function automatic logic [2:0] sel_first(input logic [5:0] m);
        casez (m)
            6'b?????1: sel_first = 3'd0;
            6'b????10: sel_first = 3'd1;
            6'b???100: sel_first = 3'd2;
            6'b??1000: sel_first = 3'd3;
            6'b?10000: sel_first = 3'd4;
            6'b100000: sel_first = 3'd5;
            default:   sel_first = 3'd0;
        endcase
    endfunction

endmodule
