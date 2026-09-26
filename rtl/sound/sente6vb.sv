// SPDX-License-Identifier: GPL-3.0-or-later
//
// The 6VB audio board: Z80, 8253, the CEM3394 control path and voices
// (sente6vb_audio), the calibration flip-flop and its clock, and the 6850 at
// its end of the serial link. The main program sends it a byte at boot and
// waits for the answer, which comes when this board's program has measured its
// voices (docs/HARDWARE_NOTES.md, "The ACIA is not optional").
//
// From sente6vb.cpp. Memory map:
//   0000-1FFF  ROM, the board's own, the same for every game
//   2000-5FFF  RAM
//   6000-7FFF  ACIA write (A0 selects, mirrored)
//   E000-FFFF  ACIA read  (A0 selects, mirrored)
// I/O (global mask 0xff) is rtl/sound/sente6vb_io.sv.
//
// Interrupts:
//   IRQ  8253 counter 2 OUT, a level
//   NMI  the ACIA's IRQ, sampled on each rising edge of the 500 kHz UART clock
//        while counter-control bit 5 is set, and cleared when a write takes bit
//        5 from 1 to 0 (uart_clock_w, counter_control_w)
//
// Clocks. The board's 8 MHz crystal gives 4 MHz to the Z80, 2 MHz to counters
// 1 and 2, and 500 kHz to both ACIAs; here all three are enables off the
// core's 40 MHz. uart_clk_out is the main board's ACIA clock, the inverse of
// this board's (`m_clock_out_cb(!state)`).

module sente6vb (
    input  logic        clk,            // 40 MHz
    input  logic        rst_n,

    // The board's 8 KB ROM; answers a cycle late.
    output logic [12:0] rom_addr,
    input  logic [7:0]  rom_q,

    // The serial link.
    input  logic        rxd,            // from the main board's ACIA
    output logic        txd,            // to the main board's ACIA
    output logic        uart_clk_out,   // the main board's ACIA clock

    input  logic        pause,          // freezes the board between Z80 clocks

    output logic        audio_en,       // counter-control bit 0
    output logic        pit_unsupported,

    // The six voices, mixed: 96 kHz, one new value per sample_valid.
    output logic signed [15:0] audio,
    output logic [7:0]  audio_late      // ticks that found a sample unfinished

);

    // -------------------------------------------------------------- clocks
    // c10 divides 40 MHz to the Z80's 4 MHz; c8 counts Z80 clocks, so 2 MHz is
    // every second one and the UART clock toggles every fourth (500 kHz).
    // Pause stops every enable together, sampled between Z80 clocks, so the
    // CPU, the 8253's 2 MHz and both ACIAs' clock hold their relative phase.
    logic [3:0] c10;
    logic [2:0] c8;
    logic       uart_state, run;
    wire        clken     = run && (c10 == 4'd0);
    wire        tick_2mhz = clken && !c8[0];
    wire        uart_rise = clken && (c8[1:0] == 2'd3) && !uart_state;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c10 <= '0; c8 <= '0; uart_state <= 1'b0; run <= 1'b1;
        end else begin
            c10 <= (c10 == 4'd9) ? 4'd0 : c10 + 4'd1;
            if (c10 == 4'd9) run <= !pause;
            if (clken) begin
                c8 <= c8 + 3'd1;
                if (c8[1:0] == 2'd3) uart_state <= ~uart_state;
            end
        end
    end
    assign uart_clk_out = ~uart_state;

    // ----------------------------------------------------------------- CPU
    wire        m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n, busak_n;
    wire [15:0] addr;
    wire [7:0]  dout;
    logic [7:0] din;
    logic       nmi, irq;

    T80se #(.Mode(0), .T2Write(0), .IOWait(1)) u_cpu (
        .RESET_n(rst_n), .CLK_n(clk), .CLKEN(clken),
        .WAIT_n(1'b1), .INT_n(~irq), .NMI_n(~nmi), .BUSRQ_n(1'b1),
        .M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
        .RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n),
        .HALT_n(halt_n), .BUSAK_n(busak_n),
        .A(addr), .DI(din), .DO(dout)
    );

    wire mem    = !mreq_n && rfsh_n;
    wire in_rom = addr[15:13] == 3'b000;
    wire in_ram = addr >= 16'h2000 && addr <= 16'h5fff;
    wire in_aw  = addr[15:13] == 3'b011;                  // 6000-7FFF
    wire in_ar  = addr[15:13] == 3'b111;                  // E000-FFFF

    assign rom_addr = addr[12:0];

    // RAM, 16 KB. Registered read; the Z80 samples several enables later.
    logic [7:0] ram [0:16383];
    logic [7:0] ram_q;
    wire  [13:0] ram_a = addr[13:0] - 14'h2000;
    always_ff @(posedge clk) begin
        ram_q <= ram[ram_a];
        if (clken && mem && !wr_n && in_ram) ram[ram_a] <= dout;
    end

    // One pulse per bus access, on the first enable of the cycle: an ACIA
    // access has side effects, and a Z80 cycle spans several enables.
    logic wr_d, rd_d, iorq_d;
    always_ff @(posedge clk) if (clken) begin
        wr_d <= wr_n; rd_d <= rd_n; iorq_d <= iorq_n;
    end
    wire mem_wr_start = clken && mem && !wr_n && wr_d;
    wire mem_rd_start = clken && mem && !rd_n && rd_d;

    // ------------------------------------------------------------- the ACIA
    wire [7:0] acia_q;
    wire       acia_irq_n;
    // The read's side effects land at the end of the strobe's clock, which is
    // also when the Z80 samples its bus, so the value it gets is acia_q during
    // the strobe and acia_hold, the value at the strobe, after it.
    logic [7:0] acia_hold;
    wire       acia_access = (mem_wr_start && in_aw) || (mem_rd_start && in_ar);

    acia6850 u_acia (
        .clk(clk), .rst_n(rst_n),
        .access(acia_access), .rnw(!(mem_wr_start && in_aw)), .rs(addr[0]),
        .din(dout), .dout(acia_q),
        .txc(uart_state), .rxc(uart_state),
        .rxd(rxd), .cts(1'b0), .dcd(1'b0),
        .txd(txd), .rts(), .irq_n(acia_irq_n)
    );
    always_ff @(posedge clk) if (mem_rd_start && in_ar) acia_hold <= acia_q;

    // ---------------------------------------------------------------- I/O
    wire        io_cs = clken && !iorq_n && iorq_d && m1_n;
    wire [7:0]  io_dout;
    wire        cv_valid, ctrl_gate, cs_update, osc_tick;
    wire [2:0]  cv_chip, cv_reg;
    wire [5:0]  cv_mask, counter_control;
    wire [11:0] cv_dac;
    wire [2:0]  pit_out;

    sente6vb_io u_io (
        .clk(clk), .rst_n(rst_n),
        .io_cs(io_cs), .io_wr(!wr_n), .io_addr(addr[7:0]), .io_din(dout),
        .io_dout(io_dout),
        .clk_2mhz_tick(tick_2mhz), .osc_clk(osc_tick),
        .cv_valid(cv_valid), .cv_chip(cv_chip), .cv_reg(cv_reg), .cv_dac(cv_dac),
        .cv_mask(cv_mask),
        .ctrl_gate(ctrl_gate), .cs_update(cs_update),
        .counter_control(counter_control), .pit_out(pit_out),
        .pit_unsupported(pit_unsupported)
    );

    sente6vb_c0timer u_c0 (
        .clk(clk), .rst_n(rst_n),
        .cv_valid(cv_valid), .cv_mask(cv_mask), .cv_reg(cv_reg), .cv_dac(cv_dac),
        .ctrl_gate(ctrl_gate), .cs_update(cs_update),
        .tick(osc_tick)
    );

    assign audio_en = counter_control[0];

    // --------------------------------------------------------------- audio
    // 96 kHz on average from 40 MHz: 2^32 * 96000/40e6 per cycle, a tick on
    // each carry. Held while paused, so the voices freeze with the CPU.
    logic [31:0] srate_acc;
    logic        sample_tick;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            srate_acc <= '0; sample_tick <= 1'b0;
        end else if (pause) begin
            sample_tick <= 1'b0;
        end else begin
            {sample_tick, srate_acc} <= {1'b0, srate_acc} + 33'd10307922;
        end
    end

    sente6vb_audio u_audio (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick),
        .cv_valid(cv_valid), .cv_mask(cv_mask), .cv_reg(cv_reg), .cv_dac(cv_dac),
        .audio_en(counter_control[0]),
        .sample(audio), .sample_valid(), .late(audio_late), .param_overrun()
    );

    // -------------------------------------------------------- interrupts
    logic nmi_en_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nmi <= 1'b0; nmi_en_d <= 1'b0;
        end else begin
            nmi_en_d <= counter_control[5];
            if (nmi_en_d && !counter_control[5]) nmi <= 1'b0;
            else if (uart_rise && counter_control[5]) nmi <= !acia_irq_n;
        end
    end
    assign irq = pit_out[2];

    // ------------------------------------------------------------ data in
    // The interrupt acknowledge reads 0xFF: nothing drives the bus (MAME's Z80
    // with no daisy chain). Unmapped memory reads 0x00, MAME's unmap value.
    always_comb begin
        if (!iorq_n && !m1_n) din = 8'hff;
        else if (!iorq_n)     din = io_dout;
        else if (in_rom)      din = rom_q;
        else if (in_ram)      din = ram_q;
        else if (in_ar)       din = mem_rd_start ? acia_q : acia_hold;
        else                  din = 8'h00;
    end

endmodule
