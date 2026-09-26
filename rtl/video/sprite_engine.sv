// SPDX-License-Identifier: GPL-3.0-or-later
//
// The sprite overlay, built one line ahead into a ping-pong line buffer.
//
// The board races the beam (docs/HARDWARE_NOTES.md, "Raster timing"): every set
// writes sprite RAM during active display, so nothing may be latched a frame
// ahead. This walks the 40 entries during one line and fills the buffer the
// NEXT line displays, which is the shortest latency a line-based engine can
// have and the assumption the beam model uses.
//
// THE LINE BUFFER HOLDS THE SPRITE NIBBLE, NOT A COLOUR AND NOT A COMPOSED
// INDEX. A sprite pixel is the HIGH nibble of a palette index and the
// background supplies the low nibble, and each sprite reads that low nibble
// from the BACKGROUND rather than from an earlier sprite's result
// (balsente_v.cpp: `old` points into the expanded video RAM). Overlapping
// sprite pixels are common -- 27 to 110 a frame across the captures in debug/,
// up to two deep -- so composing here would hand the second sprite the first
// one's low nibble. Nibble 0 is transparent, so no separate valid bit is needed.
//
// Sprite list: 40 entries at `(0xe0 + i*4) & 0xff`, so the eight at 0xe0-0xff
// first and then the thirty-two at 0x00-0x9f. Later entries overwrite earlier
// ones: there is no priority, only order.
//
//   +0  bit 7 flip Y, bit 6 flip X, bits 2:0 image number high bits
//   +1  image number low 8 bits
//   +2  Y position, offset by 17 and then by VBEND, wrapping at 256
//   +3  X position
//
// WHICH ROW LANDS ON THIS LINE. MAME walks ypos from `sprite[2] + 17 + VBEND`
// -- which reaches 288 and is NOT masked on the first iteration -- masking only
// after each increment. So row k sits at `(ypos0 + k) & 255` for k >= 1 and at
// ypos0 itself for k = 0. Inverting: k = (line - ypos0) & 255, valid when
// k <= 15, except that k = 0 additionally requires ypos0 to be the line exactly
// rather than the line plus 256. A sprite near the bottom therefore has its
// first rows fall off the end and the rest wrap to the top, and that is
// reproduced rather than tidied.
//
// BOTH READ PORTS ANSWER A CYCLE LATE, which is what a block RAM does and what
// the fetch counters below are shaped around: an address issued in cycle c is
// readable in cycle c+2, because the RAM loads its output register during c+1.
// Getting that wrong reads each sprite's Y from its X.
//
// Cycle cost: 256 to clear, then per sprite 5 to read the entry and, when it is
// on this line, 6 more for the row and 8 to write it. Worst case
// 256 + 40*19 = 1,016 of the 2,560 clk_sys cycles in a 64 us line.

module sprite_engine #(
    parameter logic [8:0] VBEND = 9'd16
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        line_start,   // begin filling for `build_line`
    input  logic [8:0]  build_line,   // absolute scanline whose sprites to draw
    // Which half of the line buffer to fill: the parity of the line that will
    // DISPLAY it. That is build_line's parity except under flip screen, where
    // the display shows line 271 - L and the two parities are opposite.
    input  logic        build_sel,

    // Sprite RAM read port, registered.
    output logic [7:0]  sram_addr,
    input  logic [7:0]  sram_q,

    // Sprite ROM read port, registered. 64 bytes an image, 4 bytes a row.
    output logic [15:0] rom_addr,
    input  logic [7:0]  rom_q,

    // Read side: the nibble for `disp_x` of the line being displayed.
    // `disp_sel` is that line's parity -- see the note on the buffers below.
    input  logic        disp_sel,
    input  logic [7:0]  disp_x,
    output logic [3:0]  disp_nibble,

    output logic        busy
);

    // 512 x 4: two line buffers in one block RAM, one written while the other
    // is read. WHICH IS WHICH IS THE LINE'S PARITY, not a flipping register.
    // A toggle has an edge case at every line boundary: the first pixel of a
    // line is fetched during the last pixel of the previous one, before a
    // toggle at line start would have happened, so pixel 0 reads the wrong
    // buffer. Indexing by parity makes the buffer a function of the line
    // number, and the caller asks for the line it is fetching.
    logic [3:0] lbuf [0:511];
    logic [8:0] bl;                   // the line being filled, latched
    logic       fill;                 // and the half it goes in
    logic       lb_we;
    logic [8:0] lb_waddr;
    logic [3:0] lb_wdata;

    always_ff @(posedge clk) begin
        if (lb_we) lbuf[lb_waddr] <= lb_wdata;
        disp_nibble <= lbuf[{disp_sel, disp_x}];
    end

    typedef enum logic [2:0] {
        S_IDLE, S_CLEAR, S_ENTRY, S_ROW, S_PIX, S_NEXT
    } state_t;

    state_t      st;
    logic [5:0]  idx;                 // sprite 0..39
    logic [2:0]  cnt;                 // fetch phase
    logic [7:0]  clr;
    logic [7:0]  sb [0:3];            // the entry
    logic [7:0]  gfx [0:3];           // one row of the image
    logic [8:0]  ypos0;
    logic [2:0]  pix;                 // 0..7 across the row
    logic [15:0] row_base;

    wire [7:0]  entry_addr = 8'hE0 + {idx, 2'b00};   // wraps in 8 bits by design
    wire [10:0] image      = {sb[0][2:0], sb[1]};
    wire        flipx      = sb[0][6];
    wire        flipy      = sb[0][7];
    wire [7:0]  xpos       = sb[3];

    wire [7:0]  kdiff      = bl[7:0] - ypos0[7:0];
    wire        k_ok       = (kdiff <= 8'd15) &&
                             !((kdiff == 8'd0) && (ypos0 > 9'd255));
    wire        row_ok     = (bl >= (9'd16 + VBEND)) && (bl <= 9'd255);
    wire [3:0]  krow       = flipy ? (4'd15 - kdiff[3:0]) : kdiff[3:0];
    wire [15:0] base_addr  = (16'(image) << 6) + {10'b0, krow, 2'b00};

    // The pixel being written. 9 bits, because MAME keeps currx as an int and
    // clips at 256: a sprite at x=252 loses its right-hand pixels rather than
    // wrapping to the left edge.
    wire [1:0]  gsel  = flipx ? (2'd3 - pix[2:1]) : pix[2:1];
    wire [7:0]  gdat  = gfx[gsel];
    wire [3:0]  nib   = flipx ? (pix[0] ? gdat[7:4] : gdat[3:0])
                              : (pix[0] ? gdat[3:0] : gdat[7:4]);
    wire [8:0]  currx = {1'b0, xpos} + {6'b0, pix};

    assign busy = (st != S_IDLE);

    always_comb begin
        lb_we    = 1'b0;
        lb_waddr = {fill, clr};
        lb_wdata = 4'd0;
        if (st == S_CLEAR) begin
            lb_we = 1'b1;
        end else if (st == S_PIX && nib != 4'd0 && currx < 9'd256) begin
            lb_we    = 1'b1;
            lb_waddr = {fill, currx[7:0]};
            lb_wdata = nib;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; idx <= '0; cnt <= '0; clr <= '0; pix <= '0;
            sram_addr <= '0; rom_addr <= '0; ypos0 <= '0; row_base <= '0;
            bl <= '0; fill <= 1'b0;
        end else begin
            case (st)
                S_IDLE: if (line_start) begin
                    bl   <= build_line;
                    fill <= build_sel;
                    clr  <= '0;
                    st   <= S_CLEAR;
                end

                S_CLEAR: begin
                    if (clr == 8'd255) begin
                        idx       <= '0;
                        cnt       <= '0;
                        sram_addr <= 8'hE0;
                        st        <= row_ok ? S_ENTRY : S_IDLE;
                    end else begin
                        clr <= clr + 8'd1;
                    end
                end

                // Address issued at cnt 0..2 for bytes 1..3; byte c-1 readable
                // at cnt c, because the address for byte 0 was issued the cycle
                // before this state was entered.
                S_ENTRY: begin
                    if (cnt < 3'd3) sram_addr <= entry_addr + 8'(cnt) + 8'd1;
                    if (cnt > 3'd0) sb[2'(cnt - 3'd1)] <= sram_q;
                    if (cnt == 3'd4) begin
                        // sb[2] settled last cycle; sram_q right now is byte 3
                        ypos0 <= 9'(sb[2]) + 9'd17 + VBEND;
                        cnt   <= '0;
                        st    <= S_ROW;
                    end else begin
                        cnt <= cnt + 3'd1;
                    end
                end

                S_ROW: begin
                    if (cnt == 3'd0) begin
                        if (!k_ok) begin
                            st <= S_NEXT;
                        end else begin
                            row_base <= base_addr;
                            rom_addr <= base_addr;
                            cnt      <= 3'd1;
                        end
                    end else begin
                        if (cnt <= 3'd3) rom_addr <= row_base + 16'(cnt);
                        if (cnt >= 3'd2) gfx[2'(cnt - 3'd2)] <= rom_q;
                        if (cnt == 3'd5) begin
                            pix <= '0;
                            st  <= S_PIX;
                        end else begin
                            cnt <= cnt + 3'd1;
                        end
                    end
                end

                S_PIX: begin
                    if (pix == 3'd7) st <= S_NEXT;
                    else             pix <= pix + 3'd1;
                end

                S_NEXT: begin
                    if (idx == 6'd39) begin
                        st <= S_IDLE;
                    end else begin
                        idx       <= idx + 6'd1;
                        cnt       <= '0;
                        sram_addr <= 8'hE0 + {(idx + 6'd1), 2'b00};
                        st        <= S_ENTRY;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
