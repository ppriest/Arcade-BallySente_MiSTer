// SPDX-License-Identifier: GPL-3.0-or-later
//
// Motorola 6850 ACIA, transcribed from MAME's devices/machine/6850acia.cpp.
//
// Both boards have one: the main board's talks to the 6VB and the 6VB's talks
// back. It is transcribed rather than written from the datasheet for the same
// reason as the 8253 (rtl/sound/pit8253.sv): MAME is the reference, and the
// main program's timing depends on details the datasheet leaves open.
//
// WHY A SILENT CORE NEEDS IT. cshift sends 0xE0 at boot and polls status until
// the 6VB answers, which it does when its calibration ends (frame 560 in MAME);
// after that it streams commands one character time apart -- ~400 CPU cycles,
// 10 bits x 16 / 500 kHz -- pacing itself on TDRE (docs/HARDWARE_NOTES.md,
// "The ACIA is not optional").
//
// THE PROTOCOL cshift uses, from MAME's trace. Control 0x35 enables the
// transmit interrupt; with TDRE set that fires FIRQ at once, and the handler
// writes 0x15 (transmit interrupt off) and a data byte. Streaming after that is
// polled, so status reads return 0x02 -- TDRE set, IRQ clear -- on every one of
// MAME's 479,062 polls.
//
// Clocks are LEVELS sampled on clk_sys and edge-detected here, as in the 8253:
//   txc  the transmitter advances on a FALLING edge   (write_txc: `!state`)
//   rxc  the receiver advances on a RISING edge       (write_rxc: `state`)
// On this board both are the 6VB's 500 kHz clock, inverted.
//
// The IRQ output is delayed one clk_sys cycle, standing in for MAME's
// `scheduler().synchronize()` in output_irq(): the status IRQ bit and the pin
// both change after the access that caused them, not during it.

module acia6850 (
    input  logic       clk,
    input  logic       rst_n,

    // CPU bus. `access` is one cycle per bus access, at the end of the cycle.
    input  logic       access,
    input  logic       rnw,
    input  logic       rs,           // 0 control/status, 1 data
    input  logic [7:0] din,
    output logic [7:0] dout,         // combinational, valid while addressed

    input  logic       txc,
    input  logic       rxc,
    input  logic       rxd,
    input  logic       cts,          // active high inhibits the transmitter
    input  logic       dcd,

    output logic       txd,
    output logic       rts,
    output logic       irq_n
);

    localparam logic [7:0] SR_RDRF = 8'h01, SR_TDRE = 8'h02, SR_DCD = 8'h04,
                           SR_CTS  = 8'h08, SR_FE   = 8'h10, SR_OVRN = 8'h20,
                           SR_PE   = 8'h40, SR_IRQ  = 8'h80;

    localparam logic [1:0] PAR_NONE = 2'd0, PAR_ODD = 2'd1, PAR_EVEN = 2'd2;
    localparam logic [1:0] ST_START = 2'd0, ST_DATA = 2'd1, ST_STOP = 2'd2;
    localparam logic [1:0] DCD_NONE = 2'd0, DCD_READ_STATUS = 2'd1, DCD_READ_DATA = 2'd2;

    logic [7:0] status, tdr, rdr;
    logic [6:0] divide;              // 0, 1, 16 or 64
    logic [3:0] nbits;               // 7 or 8
    logic [1:0] parity;
    logic [1:0] stopbits;
    logic       brk, tx_ie, rx_ie;
    logic       first_master_reset;
    logic [1:0] dcd_pending;
    logic       overrun_pending;

    logic       txc_d, rxc_d;
    logic [1:0] tx_state, rx_state;
    logic [6:0] tx_counter, rx_counter;
    logic [3:0] tx_bits, rx_bits;
    logic [7:0] tx_shift, rx_shift;
    logic       tx_parity, rx_parity;

    logic       irq_q;               // MAME's m_irq: 1 = inactive

    // ------------------------------------------------------------ reads
    // status_r() masks TDRE while in master reset or while CTS is high.
    wire [7:0] status_view = (divide == 7'd0 || status[3])
                           ? (status & ~SR_TDRE) : status;
    assign dout = rs ? rdr : status_view;

    // calculate_txirq() / calculate_rxirq(), both active low
    wire txirq_n = !(tx_ie && (divide != 7'd0) && status[1] && !status[3]);
    wire rxirq_n = !(rx_ie && (divide != 7'd0) && (status[0] || dcd_pending != DCD_NONE));
    wire irq_now = txirq_n && rxirq_n;

    always_ff @(posedge clk or negedge rst_n) begin
        logic [7:0] st;
        logic [6:0] dv;
        logic [2:0] ws;

        if (!rst_n) begin
            status <= SR_TDRE; tdr <= '0; rdr <= '0;
            divide <= '0; nbits <= 4'd8; parity <= PAR_NONE; stopbits <= 2'd1;
            brk <= 1'b0; tx_ie <= 1'b0; rx_ie <= 1'b0;
            first_master_reset <= 1'b1; dcd_pending <= DCD_NONE;
            overrun_pending <= 1'b0;
            txc_d <= 1'b0; rxc_d <= 1'b0;
            tx_state <= ST_START; rx_state <= ST_START;
            tx_counter <= '0; rx_counter <= '0;
            tx_bits <= '0; rx_bits <= '0; tx_shift <= '0; rx_shift <= '0;
            tx_parity <= 1'b0; rx_parity <= 1'b0;
            txd <= 1'b1; rts <= 1'b1;       // device_reset()
            irq_q <= 1'b1; irq_n <= 1'b1;
        end else begin
            st = status;
            txc_d <= txc;
            rxc_d <= rxc;

            // ------------------------------------------------ CTS and DCD pins
            st = cts ? (st | SR_CTS) : (st & ~SR_CTS);

            // ------------------------------------------------------- bus
            if (access) begin
                if (!rnw && !rs) begin
                    // control_w()
                    case (din[1:0])
                        2'd0: dv = 7'd1;
                        2'd1: dv = 7'd16;
                        2'd2: dv = 7'd64;
                        default: dv = 7'd0;
                    endcase
                    divide <= dv;
                    ws = din[4:2];
                    case (ws)
                        3'd0: begin nbits <= 4'd7; parity <= PAR_EVEN; stopbits <= 2'd2; end
                        3'd1: begin nbits <= 4'd7; parity <= PAR_ODD;  stopbits <= 2'd2; end
                        3'd2: begin nbits <= 4'd7; parity <= PAR_EVEN; stopbits <= 2'd1; end
                        3'd3: begin nbits <= 4'd7; parity <= PAR_ODD;  stopbits <= 2'd1; end
                        3'd4: begin nbits <= 4'd8; parity <= PAR_NONE; stopbits <= 2'd2; end
                        3'd5: begin nbits <= 4'd8; parity <= PAR_NONE; stopbits <= 2'd1; end
                        3'd6: begin nbits <= 4'd8; parity <= PAR_EVEN; stopbits <= 2'd1; end
                        3'd7: begin nbits <= 4'd8; parity <= PAR_ODD;  stopbits <= 2'd1; end
                    endcase
                    // transmitter_control[4][3] = {rts, brk, tx_ie}
                    case (din[6:5])
                        2'd0: begin rts <= 1'b0; brk <= 1'b0; tx_ie <= 1'b0; end
                        2'd1: begin rts <= 1'b0; brk <= 1'b0; tx_ie <= 1'b1; end
                        2'd2: begin rts <= 1'b1; brk <= 1'b0; tx_ie <= 1'b0; end
                        2'd3: begin rts <= 1'b0; brk <= 1'b1; tx_ie <= 1'b0; end
                    endcase
                    rx_ie <= din[7];

                    if (dv == 7'd0) begin
                        // master reset
                        if (first_master_reset) begin
                            rts <= 1'b1;
                            first_master_reset <= 1'b0;
                        end
                        dcd_pending     <= DCD_NONE;
                        overrun_pending <= 1'b0;
                        rx_state   <= ST_START;
                        rx_counter <= '0;
                        tx_state   <= ST_START;
                        txd        <= 1'b1;
                        st = st | SR_TDRE;
                        st = st & (SR_CTS | SR_TDRE);
                        if (dcd) st = st | SR_DCD;
                    end
                end else if (!rnw && rs) begin
                    // data_w(): ignored while in master reset
                    if (divide != 7'd0) begin
                        tdr <= din;
                        st  = st & ~SR_TDRE;
                    end
                end else if (rnw && !rs) begin
                    // status_r() side effect
                    if (dcd_pending == DCD_READ_STATUS) dcd_pending <= DCD_READ_DATA;
                end else begin
                    // data_r() side effects
                    if (overrun_pending) begin
                        st = st | SR_OVRN;
                        overrun_pending <= 1'b0;
                    end else begin
                        st = st & ~SR_OVRN & ~SR_RDRF;
                    end
                    if (dcd_pending == DCD_READ_DATA) dcd_pending <= DCD_NONE;
                end
            end

            // --------------------------------------------------- transmitter
            // write_txc(): on a falling edge, with a divider selected
            if (txc_d && !txc && divide != 7'd0) begin
                case (tx_state)
                    ST_START: begin
                        tx_counter <= '0;
                        if (!st[1] && !st[3]) begin
                            tx_state  <= ST_DATA;
                            tx_shift  <= tdr;
                            tx_bits   <= '0;
                            tx_parity <= 1'b0;
                            st = st | SR_TDRE;
                            txd <= 1'b0;                  // start bit
                        end else begin
                            txd <= !brk;
                        end
                    end
                    ST_DATA: begin
                        if (tx_counter + 7'd1 == divide) begin
                            tx_counter <= '0;
                            if (tx_bits < nbits) begin
                                txd       <= tx_shift[tx_bits[2:0]];
                                tx_bits   <= tx_bits + 4'd1;
                                tx_parity <= tx_parity ^ tx_shift[tx_bits[2:0]];
                            end else if (tx_bits == nbits && parity != PAR_NONE) begin
                                tx_bits <= tx_bits + 4'd1;
                                txd     <= (parity == PAR_ODD) ? !tx_parity : tx_parity;
                            end else begin
                                tx_state <= ST_STOP;
                                tx_bits  <= '0;
                                txd      <= 1'b1;
                            end
                        end else begin
                            tx_counter <= tx_counter + 7'd1;
                        end
                    end
                    ST_STOP: begin
                        if (tx_counter + 7'd1 == divide) begin
                            tx_counter <= '0;
                            if (tx_bits + 4'd1 == 4'(stopbits)) tx_state <= ST_START;
                            tx_bits <= tx_bits + 4'd1;
                        end else begin
                            tx_counter <= tx_counter + 7'd1;
                        end
                    end
                    default: tx_state <= ST_START;
                endcase
            end

            // ------------------------------------------------------ receiver
            // write_rxc(): on a rising edge, with a divider selected
            if (!rxc_d && rxc && divide != 7'd0) begin
                if (dcd) begin
                    if (!st[2]) begin
                        st = st | SR_DCD;
                        dcd_pending <= DCD_READ_STATUS;
                    end
                    rx_state   <= ST_START;
                    rx_counter <= '0;
                end else begin
                    if (dcd_pending == DCD_NONE) st = st & ~SR_DCD;
                    case (rx_state)
                        ST_START: begin
                            if (!rxd) begin
                                if (rx_counter + 7'd1 >= (divide >> 1)) begin
                                    rx_state  <= ST_DATA;
                                    rx_counter <= '0;
                                    rx_shift  <= '0;
                                    rx_parity <= 1'b0;
                                    rx_bits   <= '0;
                                end else begin
                                    rx_counter <= rx_counter + 7'd1;
                                end
                            end else begin
                                rx_counter <= '0;
                            end
                        end
                        ST_DATA: begin
                            if (rx_counter + 7'd1 == divide) begin
                                logic [7:0] sh;
                                logic [3:0] nb;
                                rx_counter <= '0;
                                // MAME shifts the parity bit in too, as bit 8 of an
                                // int, and truncates it away in the 8-bit m_rdr. Here
                                // the register is 8 bits, so it has to be kept out.
                                sh = rx_shift | ((rxd && rx_bits < 4'd8) ? (8'd1 << rx_bits[2:0]) : 8'd0);
                                nb = rx_bits + 4'd1;
                                rx_shift  <= sh;
                                rx_bits   <= nb;
                                rx_parity <= rx_parity ^ rxd;
                                if ((nb == nbits && parity == PAR_NONE) ||
                                    (nb == nbits + 4'd1 && parity != PAR_NONE)) begin
                                    if (st[0]) begin
                                        overrun_pending <= 1'b1;
                                    end else begin
                                        logic p;
                                        p = rx_parity ^ rxd;
                                        if (parity == PAR_ODD) p = !p;
                                        st = (parity != PAR_NONE && p) ? (st | SR_PE)
                                                                       : (st & ~SR_PE);
                                        rdr <= (nbits == 4'd7 && parity != PAR_NONE)
                                               ? (sh & 8'h7f) : sh;
                                        st = st | SR_RDRF;
                                    end
                                    rx_state <= ST_STOP;
                                end
                            end else begin
                                rx_counter <= rx_counter + 7'd1;
                            end
                        end
                        ST_STOP: begin
                            if (rx_counter + 7'd1 == divide) begin
                                rx_counter <= '0;
                                st = rxd ? (st & ~SR_FE) : (st | SR_FE);
                                rx_state <= ST_START;
                            end else begin
                                rx_counter <= rx_counter + 7'd1;
                            end
                        end
                        default: rx_state <= ST_START;
                    endcase
                end
            end

            // -------------------------------------------------------- irq
            // One cycle late, as MAME's synchronize() is: the status bit and
            // the pin follow the access that changed them.
            irq_q <= irq_now;
            irq_n <= irq_q;
            st = irq_q ? (st & ~SR_IRQ) : (st | SR_IRQ);

            status <= st;
        end
    end

endmodule
