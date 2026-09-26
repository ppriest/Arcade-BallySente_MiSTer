// SPDX-License-Identifier: GPL-3.0-or-later
//
// The whole machine: the SAC-I main board, the 6VB on its serial link, the
// three ROMs, and the per-game configuration the .mra carries. This is what
// sim/board_tb runs and what BallySente.sv wires to the framework, so the
// ROM download path is simulated too.
//
// THE ROMs ARE BLOCK RAM, written by the download and read with one cycle of
// latency, which is what both boards were verified against (docs/ROADMAP.md,
// "Memory plan"). The download image is laid out by scripts/build_mra.py:
//
//   0x00000  maincpu, 256 KB
//   0x40000  gfx1, 64 KB
//   0x50000  the 6VB's ROM, 8 KB
//   0x52000  configuration, 32 bytes: 0 expand_roms() mask, 1 flags
//            (bit 0 SWAP_HALVES, bit 1 256 KB maincpu), 2-5 the analog ports'
//            descriptors (rtl/analog_inputs.sv), 6 the ADC (bits 1:0 shift,
//            bit 7 raw), 7 the board variant (rtl/main_bus.sv; 5 the gun),
//            16-31 the input map
//
// Configuration survives reset: MiSTer holds reset for the whole download.
//
// INPUTS. Every game wires IN0/IN1 differently, so each port bit is chosen by
// a map byte from the .mra (build_mra.py documents the encoding). Joystick
// bits follow CONF_STR's J1 line.

module balsente_core #(
    parameter bit OPEN_BUS = 1         // rtl/main_bus.sv; 0 only to compare with MAME
) (
    input  logic        clk,            // 40 MHz
    input  logic        raster_rst_n,   // power-on only: the raster never stops
    input  logic        rst_n,          // held low through the download

    // ROM download, index 0
    input  logic        dl_wr,
    input  logic [18:0] dl_addr,
    input  logic [7:0]  dl_data,

    // NOVRAM, for the .nvm file: one nibble a byte, system chip first
    input  logic        nv_ext_we,
    input  logic [8:0]  nv_ext_addr,
    input  logic [3:0]  nv_ext_din,
    output logic [3:0]  nv_ext_q,
    output logic        nv_cpu_wr,

    input  logic [31:0] joystick_0,
    input  logic [31:0] joystick_1,
    input  logic [31:0] joystick_2,     // players 3 and 4: teamht, grudge
    input  logic [31:0] joystick_3,
    input  logic [31:0] dips,           // <switches> bytes: SWH, SWG, IN0, IN1

    // Analog controls, as hps_io presents them
    input  logic [24:0] ps2_mouse,
    input  logic [15:0] stick0, stick1, stick2,
    input  logic [8:0]  spinner0, spinner1, spinner2,
    input  logic        pause,
    input  logic        flip,
    input  logic [1:0]  gun_mode,       // lightgun.sv: 0 Auto, 1 Aim, 2 D-pad
    input  logic        crosshair_off,
    output logic        gun_game,       // this set has the gun (cfg byte 7 is 5)

    output logic [3:0]  r,
    output logic [3:0]  g,
    output logic [3:0]  b,
    output logic        hsync,
    output logic        vsync,
    output logic        hblank,
    output logic        vblank,
    output logic        ce_pix,

    output logic        audio_en,
    output logic        snd_unsupported,
    output logic signed [15:0] audio,     // mono, 96 kHz sample-and-hold


    // For a bench or a probe
    output logic [15:0] cpu_addr,
    output logic        cpu_rnw,
    output logic        cen_E,
    output logic [8:0]  hpos,
    output logic [8:0]  vpos
);

    // ---------------------------------------------------------------- ROMs
    wire dl_prg = dl_wr && dl_addr[18] == 1'b0;                     // 00000-3FFFF
    wire dl_gfx = dl_wr && dl_addr[18:16] == 3'b100;                // 40000-4FFFF
    wire dl_snd = dl_wr && dl_addr[18:13] == 6'b101000;             // 50000-51FFF
    wire dl_cfg = dl_wr && dl_addr[18:5] == 14'h2900;               // 52000-5201F

    logic [7:0]  prg [0:262143];
    logic [7:0]  gfx [0:65535];
    logic [7:0]  snd [0:8191];
    logic [7:0]  prg_q, gfx_q, snd_q;
    wire  [17:0] prg_addr;
    wire  [15:0] gfx_addr;
    wire  [12:0] snd_addr;

    always_ff @(posedge clk) begin
        if (dl_prg) prg[dl_addr[17:0]] <= dl_data;
        prg_q <= prg[prg_addr];
    end
    always_ff @(posedge clk) begin
        if (dl_gfx) gfx[dl_addr[15:0]] <= dl_data;
        gfx_q <= gfx[gfx_addr];
    end
    always_ff @(posedge clk) begin
        if (dl_snd) snd[dl_addr[12:0]] <= dl_data;
        snd_q <= snd[snd_addr];
    end

    // ------------------------------------------------------- configuration
    logic [7:0] cfg [0:31];
    initial for (int i = 0; i < 32; i++) cfg[i] = (i >= 16) ? 8'hff : 8'h00;
    always_ff @(posedge clk) if (dl_cfg) cfg[dl_addr[4:0]] <= dl_data;

    // ------------------------------------------------------------- inputs
    // 0x00-0x7f joysticks 0 and 1 (bit 5 the player, bit 6 active high),
    // 0x80 a DIP, 0xa0-0xbf / 0xc0-0xdf joystick 2 / 3 active low, 0xfe/0xff 0/1.
    function automatic logic port_bit(input logic [7:0] m, input logic [31:0] j0,
                                      input logic [31:0] j1, input logic [31:0] j2,
                                      input logic [31:0] j3, input logic dip);
        logic v;
        if (m == 8'hff)      return 1'b1;
        if (m == 8'hfe)      return 1'b0;
        if (m == 8'h80)      return dip;
        if (m[7:5] == 3'b101) return ~j2[m[4:0]];
        if (m[7:5] == 3'b110) return ~j3[m[4:0]];
        v = m[5] ? j1[m[4:0]] : j0[m[4:0]];
        return m[6] ? v : ~v;
    endfunction

    // Night Stocker's trigger is also the left mouse button.
    wire v_gun = cfg[7][2:0] == 3'd5;
    assign gun_game = v_gun;

    logic [7:0] in0, in1;
    always_ff @(posedge clk) begin
        for (int i = 0; i < 8; i++) begin
            in0[i] <= port_bit(cfg[16 + i], joystick_0, joystick_1, joystick_2, joystick_3, dips[16 + i]);
            in1[i] <= port_bit(cfg[24 + i], joystick_0, joystick_1, joystick_2, joystick_3, dips[24 + i]);
        end
        if (v_gun && ps2_mouse[0]) in1[1] <= 1'b0;
    end

    // teamht's input groups (EX0-EX3): the four players' joysticks in bits
    // 7:4, active low; players 3 and 4 sit opposite, so theirs are reversed.
    function automatic logic [7:0] ex(input logic [31:0] j, input logic rev);
        // joystick bits: 0 R, 1 L, 2 D, 3 U
        ex = rev ? ~{j[0], j[1], j[3], j[2], 4'h0} : ~{j[1], j[0], j[2], j[3], 4'h0};
    endfunction

    // -------------------------------------------------------------- reset
    // The raster runs through reset, so the display keeps its sync while the
    // ROMs load; MiSTer measures the core's video and a frame with no sync in
    // it leaves HDMI in a mode the display rejects. Everything else is
    // released on the clock where the raster reaches the point reset puts it
    // at -- line 256, pixel 0, the start of a pixel -- so the machine starts
    // in the state sim/board_tb and MAME start in.
    logic running;
    wire  at_start = ce_pix && hpos == 9'd319 && vpos == 9'd255;
    always_ff @(posedge clk or negedge raster_rst_n) begin
        if (!raster_rst_n) running <= 1'b0;
        else if (!rst_n)   running <= 1'b0;
        else if (at_start) running <= 1'b1;
    end

    // ------------------------------------------------------------ analog
    wire [7:0] an0, an1, an2, an3;

    analog_inputs u_analog (
        .clk(clk), .rst_n(running), .vblank(vblank),
        .port_cfg({cfg[5], cfg[4], cfg[3], cfg[2]}),
        // On the gun set the d-pad and left stick aim, so its dial takes the
        // spinner and the right stick's left/right (joystick bits 15, 14).
        .ps2_mouse(ps2_mouse), .stick0(v_gun ? 16'd0 : stick0), .stick1(stick1),
        .dpad0(v_gun ? {2'b00, joystick_0[15:14]} : joystick_0[3:0]), .dpad1(joystick_1[3:0]),
        .spinner0(spinner0), .spinner1(spinner1),
        .an0(an0), .an1(an1), .an2(an2), .an3(an3)
    );

    wire [7:0] wheel0, wheel1, wheel2;
    grudge_wheels u_wheels (
        .clk(clk), .rst_n(running), .hblank(hblank), .ps2_mouse(ps2_mouse),
        .spinner0(spinner0), .spinner1(spinner1), .spinner2(spinner2),
        .dpad0(joystick_0[3:0]), .dpad1(joystick_1[3:0]), .dpad2(joystick_2[3:0]),
        .stick0_x(stick0[7:0]), .stick1_x(stick1[7:0]), .stick2_x(stick2[7:0]),
        .wheel0(wheel0), .wheel1(wheel1), .wheel2(wheel2)
    );

    wire [7:0] gun_x, gun_y;
    wire       crosshair;
    lightgun u_gun (
        .clk(clk), .rst_n(running), .vblank(vblank), .ps2_mouse(ps2_mouse),
        .stick(stick0), .dpad(joystick_0[3:0]), .mode(gun_mode),
        .flip(flip), .hpos(hpos), .vpos(vpos),
        .gun_x(gun_x), .gun_y(gun_y), .crosshair(crosshair)
    );

    // ------------------------------------------------------------- boards
    wire uart_clk, main_txd, snd_txd;

    wire [3:0] br, bg, bb;
    game_board #(.OPEN_BUS(OPEN_BUS)) u_main (
        .clk(clk), .rst_n(running), .raster_rst_n(raster_rst_n),
        .cfg_cdmask(cfg[0][5:0]), .cfg_swap(cfg[1][0]), .cfg_banks16(cfg[1][1]),
        .cfg_variant(cfg[7][2:0]),
        .prg_addr(prg_addr), .prg_q(prg_q),
        .gfx_addr(gfx_addr), .gfx_q(gfx_q),
        .in_swh(dips[7:0]), .in_swg(dips[15:8]), .in_in0(in0), .in_in1(in1),
        .uart_clk(uart_clk), .acia_rxd(snd_txd), .acia_txd(main_txd),
        .pause(pause), .flip(flip),
        .an0(an0), .an1(an1), .an2(an2), .an3(an3),
        .adc_shift(cfg[6][1:0]), .adc_raw(cfg[6][7]),
        .ex0(ex(joystick_0, 1'b0)), .ex1(ex(joystick_1, 1'b0)),
        .ex2(ex(joystick_2, 1'b1)), .ex3(ex(joystick_3, 1'b1)),
        .wheel0(wheel0), .wheel1(wheel1), .wheel2(wheel2),
        .gun_x(gun_x), .gun_y(gun_y),
        .nv_ext_we(nv_ext_we), .nv_ext_addr(nv_ext_addr), .nv_ext_din(nv_ext_din),
        .nv_ext_q(nv_ext_q), .nv_cpu_wr(nv_cpu_wr),
        .r(br), .g(bg), .b(bb),
        .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .ce_pix(ce_pix),
        .cpu_addr(cpu_addr), .cpu_rnw(cpu_rnw), .cen_E(cen_E),
        .hpos(hpos), .vpos(vpos)
    );

    // The gun's crosshair over the picture
    wire show_cross = v_gun && !crosshair_off && crosshair;
    assign r = show_cross ? 4'hf : br;
    assign g = show_cross ? 4'hf : bg;
    assign b = show_cross ? 4'hf : bb;

    wire signed [15:0] snd_audio;
    sente6vb u_snd (
        .clk(clk), .rst_n(running),
        .rom_addr(snd_addr), .rom_q(snd_q),
        .rxd(main_txd), .txd(snd_txd), .uart_clk_out(uart_clk),
        .pause(pause),
        .audio_en(audio_en), .pit_unsupported(snd_unsupported),
        .audio(snd_audio), .audio_late()
    );

    // MAME's level peaks near -20 dBFS in every game recorded (debug/*-snd),
    // under a MiSTer's noise floor; x8, saturating (docs/HACKS.md).
    wire signed [18:0] snd_gain = 19'(snd_audio) <<< 3;
    always_comb
        if (snd_gain > 19'sd32767)       audio = 16'sd32767;
        else if (snd_gain < -19'sd32768) audio = -16'sd32768;
        else                             audio = 16'(snd_gain);

endmodule
