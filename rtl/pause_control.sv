// SPDX-License-Identifier: GPL-3.0-or-later
//
// CPU pause, from the Fuuki core. The Pause button toggles it; other holds
// (the OSD being open) OR in as a level, so releasing one cannot clear the
// user's toggle.
//
// PAUSE_BIT follows CONF_STR's J1 line and the .mra <buttons> list, which
// scripts/build_mra.py pads to the same eight names: 4 directions, then
// Button 1-4, Start, Coin, Service, Pause -- bit 11.

module pause_control #(
	parameter int PAUSE_BIT = 11
) (
	input  logic        clk,
	input  logic        reset,

	input  logic [31:0] joystick_0,
	input  logic [31:0] joystick_1,

	input  logic        ext_pause,      // a level, not a pulse

	output logic        pause_cpu,
	output logic        pause_latched
);

	wire pause_btn = joystick_0[PAUSE_BIT] | joystick_1[PAUSE_BIT];

	logic pause_btn_d;

	always_ff @(posedge clk or posedge reset) begin
		if (reset) begin
			pause_btn_d   <= 1'b0;
			pause_latched <= 1'b0;
		end else begin
			pause_btn_d <= pause_btn;
			if (pause_btn && !pause_btn_d)
				pause_latched <= ~pause_latched;
		end
	end

	assign pause_cpu = pause_latched | ext_pause;

endmodule
