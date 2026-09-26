// SPDX-License-Identifier: GPL-3.0-or-later
//
// The main board's ADC, as balsente_m.cpp models it (adc_select_w,
// adc_finished, adc_data_r).
//
// A write to 0x9000-0x9007 selects a channel and starts a conversion that ends
// 50 us later -- a later select restarts it (MAME re-arms its timer; Mini Golf
// depends on the delay). Channels come in pairs, one per analog port: the even
// one reads the sign, 0xff or 0x00, the odd one the magnitude. The port value
// is shifted left by the game's `adc_shift`, pushed 8 further from zero ("most
// games seem to have a dead zone in the middle"), and clipped to 255. With
// `raw` (MAME's shift of 32, Stompin' and Shrike) the channel reads its port
// directly. A read of 0x9400 returns the last result.

module adc (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [2:0]  sel,
    input  logic [7:0]  an0, an1, an2, an3,   // signed
    input  logic [1:0]  shift,
    input  logic        raw,
    output logic [7:0]  q
);

    localparam logic [11:0] T50US = 12'd2000;   // 50 us at 40 MHz

    logic [11:0] cnt;
    logic [2:0]  ch;
    logic        busy;

    function automatic logic [7:0] pick(input logic [1:0] i, input logic [7:0] a0, a1, a2, a3);
        case (i)
            2'd0: pick = a0;
            2'd1: pick = a1;
            2'd2: pick = a2;
            default: pick = a3;
        endcase
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        logic signed [15:0] v;
        if (!rst_n) begin
            cnt <= '0; ch <= '0; busy <= 1'b0; q <= '0;
        end else if (start) begin
            ch <= sel; cnt <= T50US; busy <= 1'b1;
        end else if (busy) begin
            if (cnt != 12'd1) cnt <= cnt - 12'd1;
            else begin
                busy <= 1'b0;
                if (raw) begin
                    q <= ch[2] ? 8'h00 : pick(ch[1:0], an0, an1, an2, an3);
                end else begin
                    v = 16'(signed'(pick(ch[2:1], an0, an1, an2, an3))) <<< shift;
                    if (v < 0)      v = v - 16'sd8;
                    else if (v > 0) v = v + 16'sd8;
                    if (v < -16'sd255) v = -16'sd255;
                    if (v > 16'sd255)  v = 16'sd255;
                    if (!ch[0]) q <= (v < 0) ? 8'hff : 8'h00;
                    else        q <= (v < 0) ? 8'(-v) : 8'(v);
                end
            end
        end
    end

endmodule
