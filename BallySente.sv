// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bally/Sente SAC-I for MiSTer: framework glue only. The machine is
// rtl/balsente_core.sv, the module sim/board_tb runs; this file wires it to
// hps_io, the PLL and the video chain.
//
// Downloads:
//   index 0    ROMs and configuration (layout: scripts/build_mra.py)
//   index 4    the NOVRAM file, <nvram index="4" size="512">: one nibble a
//              byte, the system X2212 then the cartridge one
//   index 254  DIP switches: SWH, SWG, then the DIP bits of IN0 and IN1
//
// No SDRAM: the ROMs are block RAM (docs/ROADMAP.md, "Memory plan"). DDR3 is
// the HDMI rotator's alone.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// The 6VB's six voices, mono (sente6vb.cpp routes all six to one speaker).
// OSD order Mono, None, 25%, 50% is AUDIO_MIX 3, 0, 1, 2, so the default is mono.
wire signed [15:0] core_audio;
assign AUDIO_S   = 1;
assign AUDIO_L   = core_audio;
assign AUDIO_R   = core_audio;
assign AUDIO_MIX = (status[124:123] == 2'd0) ? 2'd3 : status[124:123] - 2'd1;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"

// H1: options that only reach the HDMI scaler, hidden under direct video.
// H2: the gun (Night Stocker), hidden for every other set.
localparam CONF_STR = {
	"BallySente;;",
	"-;",
	"H1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"H1O[64:63],Orientation,Off,CW,CCW;",
	"O[65],Flip Screen,Off,On;",
	"H1O[68:66],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"H1O[70:69],Crop,Off,216 lines,224 lines;",
	"H1O[75:71],Crop offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"O[124:123],Audio mix,Mono,None,25%,50%;",
	"-;",
	"O[6],Pause when OSD is open,Off,On;",
	"-;",
	// The left stick, as in the Seta core's Zombie Raid: Auto (full
	// deflection moves the gun like the d-pad, partial aims), Aim (always
	// aims), D-pad (always moves)
	"H2O[8:7],Gun stick,Auto,Aim,D-pad;",
	"H2O[9],Crosshair,On,Off;",
	"H2-;",
	"DIP;",
	"-;",
	"R[0],Reset;",
	// Must match the .mra <buttons> list (scripts/build_mra.py) and the input
	// map's joystick bits: 0-3 directions, 4-7 buttons, 8 Start, 9 Coin,
	// 10 Service, 11 Pause, 12-13 Start 3 and 4, 14-17 the right stick
	// (rescraid) as R, L, D, U.
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Service,Pause,Start 3,Start 4,R Right,R Left,R Down,R Up;",
	"jn,A,B,X,Y,Start,Select,L,R;",
	"V,v",`BUILD_DATE
};

wire        clk_sys, pll_locked;
wire        forced_scandoubler, direct_video;
wire [21:0] gamma_bus;
wire  [1:0] buttons;
wire [127:0] status;
wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;
wire        gun_game;    // the set has the gun: shows the OSD's H2 page
wire [15:0] joystick_l_analog_0, joystick_l_analog_1, joystick_l_analog_2;
wire [15:0] joystick_r_analog_0;
wire  [8:0] spinner_0, spinner_1, spinner_2;
wire [24:0] ps2_mouse;

wire        ioctl_download, ioctl_upload, ioctl_wr;
assign LED_USER = ioctl_download;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;
logic       nvram_save;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),

	.buttons(buttons),
	.status(status),
	.status_menumask({13'd0, ~gun_game, direct_video, 1'b0}),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.joystick_l_analog_2(joystick_l_analog_2),
	.joystick_r_analog_0(joystick_r_analog_0),
	.spinner_0(spinner_0),
	.spinner_1(spinner_1),
	.spinner_2(spinner_2),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0),

	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_din),
	.ioctl_rd()
);

///////////////////////   CLOCKS   ///////////////////////////////

// 40 MHz: the main board's E is /32 (1.25 MHz), the pixel clock /8 (5 MHz),
// and the 6VB's Z80 /10 (4 MHz).
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

///////////////////////   RESET   /////////////////////////////////

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

// Held in reset until the ROMs have been loaded once: before that the block
// RAMs hold nothing.
reg rom_loaded = 1'b0, dl_index0_seen = 1'b0;
always @(posedge clk_sys) begin
	if (ioctl_wr && ioctl_index == 16'd0) dl_index0_seen <= 1'b1;
	if (dl_index0_seen && !ioctl_download) rom_loaded <= 1'b1;
end

wire core_reset = reset | ioctl_download | ~rom_loaded;

///////////////////////   DIPs   //////////////////////////////////

// Bytes 0-3 are the board's (see balsente_core); byte 4 is the core's own:
// bit 0 the fake Flip Screen DIP, since the board has no flip of its own.
reg [39:0] dips = 40'hfeffffffff;
always @(posedge clk_sys)
	if (ioctl_wr && ioctl_index == 16'd254 && !ioctl_addr[24:3] && ioctl_addr[2:0] < 3'd5)
		dips[{ioctl_addr[2:0], 3'b000} +: 8] <= ioctl_dout;

// The OSD's Flip Screen and the fake DIP drive the one flip; set together
// they cancel.
wire flip = status[65] ^ dips[32];

///////////////////////   PAUSE   /////////////////////////////////

wire pause_cpu, pause_latched;
pause_control u_pause (
	.clk(clk_sys), .reset(core_reset),
	.joystick_0(joystick_0), .joystick_1(joystick_1),
	.ext_pause(status[6] & OSD_STATUS),
	.pause_cpu(pause_cpu), .pause_latched(pause_latched)
);

///////////////////////   NOVRAM   ////////////////////////////////

// Loaded from index 4 with the core in reset; read back through the same port
// on an upload. A save is requested once the program has stopped writing for
// a second, so a burst of writes costs one SD-card write.
wire       nv_dl = ioctl_download && ioctl_index == 16'd4;
wire [3:0] nv_q;
wire       nv_cpu_wr;
assign ioctl_din = {4'h0, nv_q};

reg        nv_dirty = 1'b0;
reg [25:0] nv_quiet = 26'd0;
always @(posedge clk_sys) begin
	nvram_save <= 1'b0;
	if (nv_cpu_wr) begin
		nv_dirty <= 1'b1;
		nv_quiet <= 26'd0;
	end else if (nv_dirty) begin
		if (nv_quiet == 26'd40_000_000) begin
			nv_dirty   <= 1'b0;
			nvram_save <= 1'b1;
		end else begin
			nv_quiet <= nv_quiet + 26'd1;
		end
	end
end

///////////////////////   CORE   //////////////////////////////////

wire [3:0] core_r, core_g, core_b;
wire       core_hs, core_vs, core_hb, core_vb, core_ce;

// Player 1's right analog stick past half deflection, as joystick bits 14-17
// (R, L, D, U), the same bits the "R ..." buttons set.
wire signed [7:0] rs_x = joystick_r_analog_0[7:0], rs_y = joystick_r_analog_0[15:8];
wire [31:0] joy0 = joystick_0 | {14'd0, rs_y < -8'sd64, rs_y > 8'sd64, rs_x < -8'sd64, rs_x > 8'sd64, 14'd0};

balsente_core u_core (
	.clk(clk_sys), .raster_rst_n(pll_locked), .rst_n(~core_reset),
	.dl_wr(ioctl_wr && ioctl_index == 16'd0), .dl_addr(ioctl_addr[18:0]), .dl_data(ioctl_dout),
	.nv_ext_we(nv_dl && ioctl_wr), .nv_ext_addr(ioctl_addr[8:0]), .nv_ext_din(ioctl_dout[3:0]),
	.nv_ext_q(nv_q), .nv_cpu_wr(nv_cpu_wr),
	.joystick_0(joy0), .joystick_1(joystick_1), .joystick_2(joystick_2), .joystick_3(joystick_3),
	.dips(dips[31:0]), .pause(pause_cpu), .flip(flip),
	.gun_mode(status[8:7]), .crosshair_off(status[9]), .gun_game(gun_game),
	.ps2_mouse(ps2_mouse), .stick0(joystick_l_analog_0), .stick1(joystick_l_analog_1),
	.stick2(joystick_l_analog_2),
	.spinner0(spinner_0), .spinner1(spinner_1), .spinner2(spinner_2),
	.r(core_r), .g(core_g), .b(core_b),
	.hsync(core_hs), .vsync(core_vs), .hblank(core_hb), .vblank(core_vb),
	.ce_pix(core_ce),
	.audio_en(), .snd_unsupported(), .audio(core_audio),
	.cpu_addr(), .cpu_rnw(), .cen_E(), .hpos(), .vpos()
);

///////////////////////   VIDEO   /////////////////////////////////

wire vga_de_raw;

arcade_video #(.WIDTH(320), .DW(12), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(core_ce),

	.RGB_in({core_r, core_g, core_b}),
	.HBlank(core_hb),
	.VBlank(core_vb),
	.HSync(core_hs),
	.VSync(core_vs),

	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(vga_de_raw),
	.VGA_SL(VGA_SL),

	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// Every set is ROT0 and 4:3, or 3:4 turned. 216 of the 240 lines is exactly
// 5x on 1080.
wire [1:0]  rotate_sel = status[64:63];
wire        rotate_en  = |rotate_sel;
wire        rotate_ccw = (rotate_sel == 2'd2);
wire [1:0]  ar = status[122:121];
wire [11:0] arx = (!ar) ? (rotate_en ? 12'd3 : 12'd4) : 12'(ar - 2'd1);
wire [11:0] ary = (!ar) ? (rotate_en ? 12'd4 : 12'd3) : 12'd0;
wire [1:0]  vcrop_sel = status[70:69];
wire [11:0] crop_size = (vcrop_sel == 2'd1) ? 12'd216 :
                        (vcrop_sel == 2'd2) ? 12'd224 : 12'd0;

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_raw),
	.ARX(arx),
	.ARY(ary),
	.CROP_SIZE(crop_size),
	.CROP_OFF(status[75:71]),
	.SCALE(status[68:66])
);

// HDMI rotation (sys screen_rotate_two, via the Fuuki core): a tap, so the
// analog output keeps the native raster and a turned copy goes to DDR3 and out
// through the framework's framebuffer. Its own flip is not used: flip is the
// core's (video.sv), so HDMI and analog show the same picture.
assign FB_FORCE_BLANK = 0;

screen_rotate_two screen_rotate_two
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),

	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(1'b0),
	.two_screen(1'b0),
	.video_rotated(),

	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),

	.DDRAM_CLK(DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),
	.DDRAM_RD(DDRAM_RD)
);

endmodule
