// SPDX-License-Identifier: GPL-3.0-or-later
//
// Area, DSP count and timing for cem3394_vco alone. Inputs from an LFSR and the
// outputs XOR-reduced onto one pin, so nothing can be optimised away.

module vco_synth_top (
    input  logic clk,
    input  logic rst_n,
    input  logic stim,
    output logic result
);
    localparam int DW = 30;

    logic [31:0] pat;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) pat <= 32'h1234_5678;
        else        pat <= {pat[30:0], pat[31] ^ pat[21] ^ pat[1] ^ stim};

    logic in_valid, out_valid, busy;
    logic signed [DW-1:0] ramp, pulse, triang;
    always_ff @(posedge clk) in_valid <= pat[7] & ~busy;

    cem3394_vco dut (
        .voice(3'd0),
        .clk(clk), .rst_n(rst_n),
        .step(pat), .inv_step(pat ^ 32'h5555_5555), .pw(pat ^ 32'h0F0F_0F0F),
        .in_valid(in_valid), .out_valid(out_valid),
        .ramp(ramp), .pulse(pulse), .triang(triang), .busy(busy)
    );

    always_ff @(posedge clk) result <= ^{ramp, pulse, triang, out_valid, busy};
endmodule
