// SPDX-License-Identifier: GPL-3.0-or-later
//
// Synthesis and timing harness for mc6809i alone. Phase 0 criterion 4: standalone
// Fmax and area for the CPU at this project's settings, with nothing else in the
// design to blame or to hide behind.
//
// Not a simulation model. The CPU has more port bits than this device has pins,
// so inputs come from an LFSR pattern register and every output is XOR-reduced
// onto one pin. Left unconnected, Quartus would optimise the CPU away and report
// a flattering Fmax for an empty design. The read data D is registered rather
// than constant for the same reason: a constant lets the fitter fold the decode.

module mc6809_synth_top (
    input  logic clk,
    input  logic rst_n,
    input  logic stim,
    output logic result
);

    logic reset_n;
    assign reset_n = rst_n;

    logic [31:0] pat;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) pat <= 32'h1234_5678;
        else        pat <= {pat[30:0], pat[31] ^ pat[21] ^ pat[1] ^ stim};

    // E is clk_sys/32 and Q leads it by a quarter of the E period. The counter
    // is part of the design under test: the enables are what the core is clocked
    // by, and they are cheap, but they should be in the area number.
    logic [4:0] phase;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) phase <= 5'd0;
        else        phase <= phase + 5'd1;
    wire cen_E = (phase == 5'd0);
    wire cen_Q = (phase == 5'd16);

    logic [7:0] din;
    always_ff @(posedge clk) din <= pat[7:0] ^ 8'hA5;

    wire [15:0] ADDR;
    wire [7:0]  DOut;
    wire        RnW, BS, BA, AVMA, BUSY, LIC, OP;
    wire [111:0] RegData;

    mc6809i #(.ILLEGAL_INSTRUCTIONS("GHOST")) dut (
        .D(din), .DOut(DOut), .ADDR(ADDR), .RnW(RnW),
        .clk(clk), .cen_E(cen_E), .cen_Q(cen_Q),
        .BS(BS), .BA(BA),
        .nIRQ(pat[8]), .nFIRQ(pat[9]), .nNMI(pat[10]),
        .AVMA(AVMA), .BUSY(BUSY), .LIC(LIC),
        .nHALT(pat[11]), .nRESET(reset_n), .nDMABREQ(pat[12]),
        .OP(OP), .RegData(RegData)
    );

    // RegData is 112 bits of internal register state. It is XOR-reduced with the
    // rest rather than left dangling, so the register file cannot be optimised out.
    always_ff @(posedge clk)
        result <= ^{ADDR, DOut, RnW, BS, BA, AVMA, BUSY, LIC, OP, RegData};

endmodule
