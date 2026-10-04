// SPDX-License-Identifier: GPL-3.0-or-later
//
// True dual-port byte RAM, both ports reading and writing, one clock: Shrike
// Avenger's RAM shared by the 68000 and the 6809. dpram_dc.sv with port B's
// write enabled.
//
// SYNTHESIS INSTANTIATES altsyncram. Two always blocks writing one array are
// built from registers, with nothing more than an "unsupported read-during-
// write" note (LESSONS_LEARNED, "[Seta] A true dual-port RAM must be ONE always
// block"); a BIDIR_DUAL_PORT altsyncram is one M10K array. Both clock inputs
// are driven by the same clock -- tying clock1 to a constant is what broke this
// core's first attempt at a dual-port RAM on hardware (commit 820629d). The
// behavioural model is what simulators run; Quartus defines ALTERA_RESERVED_QIS.
// A write on both ports to one address in one clock is undefined, as on the
// M10K; the two CPUs here do not arbitrate, as MAME does not.
module dpram_tdp #(
	parameter int ADDR_WIDTH = 11
) (
	input  logic                  clk,
	input  logic [ADDR_WIDTH-1:0] a_addr,
	input  logic                  a_we,
	input  logic [7:0]            a_wdata,
	output logic [7:0]            a_rdata,
	input  logic [ADDR_WIDTH-1:0] b_addr,
	input  logic                  b_we,
	input  logic [7:0]            b_wdata,
	output logic [7:0]            b_rdata
);

`ifndef ALTERA_RESERVED_QIS
	logic [7:0] mem [0:(1 << ADDR_WIDTH) - 1];
	always_ff @(posedge clk) begin
		if (a_we) mem[a_addr] <= a_wdata;
		a_rdata <= mem[a_addr];
		if (b_we) mem[b_addr] <= b_wdata;
		b_rdata <= mem[b_addr];
	end
`else
	altsyncram #(
		.operation_mode("BIDIR_DUAL_PORT"),
		.ram_block_type("M10K"),
		.intended_device_family("Cyclone V"),
		.lpm_type("altsyncram"),
		.numwords_a(1 << ADDR_WIDTH), .widthad_a(ADDR_WIDTH), .width_a(8),
		.numwords_b(1 << ADDR_WIDTH), .widthad_b(ADDR_WIDTH), .width_b(8),
		.width_byteena_a(1), .width_byteena_b(1),
		.outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
		.address_reg_b("CLOCK1"), .indata_reg_b("CLOCK1"), .wrcontrol_wraddress_reg_b("CLOCK1"),
		.clock_enable_input_a("BYPASS"), .clock_enable_output_a("BYPASS"),
		.clock_enable_input_b("BYPASS"), .clock_enable_output_b("BYPASS"),
		.outdata_aclr_a("NONE"), .outdata_aclr_b("NONE"),
		.read_during_write_mode_mixed_ports("DONT_CARE"),
		.read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
		.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
		.power_up_uninitialized("FALSE")
	) u_ram (
		.clock0(clk), .address_a(a_addr), .data_a(a_wdata), .wren_a(a_we), .q_a(a_rdata),
		.clock1(clk), .address_b(b_addr), .data_b(b_wdata), .wren_b(b_we), .q_b(b_rdata),
		.aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
		.byteena_a(1'b1), .byteena_b(1'b1),
		.clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1),
		.rden_a(1'b1), .rden_b(1'b1), .eccstatus()
	);
`endif

endmodule
