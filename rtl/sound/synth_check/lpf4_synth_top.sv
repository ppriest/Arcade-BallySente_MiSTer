// SPDX-License-Identifier: GPL-3.0-or-later
//
// Area and timing for cem3394_lpf4 alone: how many DSP blocks and ALMs one
// voice's filter costs, and whether it closes 40 MHz. docs/CEM3394_SPIKE.md
// budgets six voices at about 12 M multiplies/s; this says what that buys.
//
// Inputs come from an LFSR and every output is XOR-reduced onto one pin, so the
// fitter cannot optimise the filter away and report an empty design.

module lpf4_synth_top (
    input  logic clk,
    input  logic rst_n,
    input  logic stim,
    output logic result
);
    localparam int DW = 30;
    localparam int CW = 26;

    logic [31:0] pat;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) pat <= 32'h1234_5678;
        else        pat <= {pat[30:0], pat[31] ^ pat[21] ^ pat[1] ^ stim};

    logic signed [DW-1:0] in_sample;
    logic                 in_valid;
    always_ff @(posedge clk) begin
        in_sample <= pat[DW-1:0];
        in_valid  <= pat[5];
    end

    logic                 out_valid, busy;
    logic signed [DW-1:0] out_sample;

    cem3394_lpf4 #(.TANH_FILE("../../../debug/cem3394/tanh_table.hex")) dut (
        .voice(3'd0),
        .clk(clk), .rst_n(rst_n),
        .alpha(pat[CW-1:0]), .beta0(pat[CW:1]), .beta1(pat[CW+1:2]),
        .beta2(pat[CW+2:3]), .beta3(pat[CW+3:4]), .alpha0(pat[CW+4:5]),
        .res(pat[CW+5:6]), .gain_comp(pat[CW-1:0] ^ 26'h155_5555),
        .in_valid(in_valid), .in_sample(in_sample),
        .out_valid(out_valid), .out_sample(out_sample), .busy(busy)
    );

    always_ff @(posedge clk) result <= ^{out_sample, out_valid, busy};
endmodule
