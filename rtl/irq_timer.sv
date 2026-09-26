// SPDX-License-Identifier: GPL-3.0-or-later
//
// The main CPU's IRQ: a vertical counter tap, "32L" on the schematic.
//
// balsente_m.cpp `interrupt_timer()`. The line it fires on is not a simple
// "every 64", and the difference is visible in a bus trace:
//
//   the first one is scanline 0, then 64, 128, 192, 256
//   after 256 it goes back to 64 -- NOT to 0
//
// so the steady state is four interrupts a frame, at 64, 128, 192 and 256, and
// scanline 0 happens once, in the first frame after reset. 256 is the first
// line of vblank, so one of the four lands there.
//
// It asserts at the start of its line and clears at the start of the next
// HBLANK -- `m_irq_off_timer->adjust(time_until_pos(param, BALSENTE_HBSTART))`
// -- which is the same line, at hpos 256. So IRQ is high for exactly the
// visible part of one scanline, 51.2 us.

module irq_timer #(
    parameter logic [8:0] HBSTART = 9'd256,
    parameter logic [8:0] VBSTART = 9'd256
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [8:0] hcnt,
    input  logic [8:0] vcnt,
    output logic       irq,         // active high; the CPU input is inverted
    // One clock as it fires, with its line: interrupt_timer()'s `param`, which
    // Grudge Match's steering and Night Stocker's gun act on.
    output logic       tick,
    output logic [8:0] tick_line
);

    logic [8:0] next_line;
    logic       armed;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_line <= 9'd0;       // the first one is scanline 0
            armed     <= 1'b0;
            irq       <= 1'b0;
            tick      <= 1'b0;
            tick_line <= '0;
        end else begin
            tick <= 1'b0;
            if (vcnt == next_line && hcnt == 9'd0 && !armed) begin
                irq       <= 1'b1;
                tick      <= 1'b1;
                tick_line <= next_line;
                armed     <= 1'b1;
                next_line <= (next_line == VBSTART) ? 9'd64 : next_line + 9'd64;
            end
            // cleared at the start of the next HBLANK, on the same line
            if (armed && hcnt >= HBSTART) begin
                irq   <= 1'b0;
                armed <= 1'b0;
            end
        end
    end

endmodule
