// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/mame_keys.sv with this core's J1 positions: Z and X must not reach
// Start and Coin; presses and releases land on the J1 bits.

module tb_keys;
  logic clk = 0; always #1 clk = ~clk;
  logic [10:0] k = 0;
  wire [31:0] k0, k1;
  mame_keys #(.BUTTONS(4), .START(8), .COIN(9), .PAUSE(11), .SERVICE(10)) u (.clk(clk), .ps2_key(k), .key0(k0), .key1(k1), .svc_coin());
  task press(input [8:0] c, input bit dn); begin k = {~k[10], dn, c}; repeat (3) @(posedge clk); end endtask
  initial begin
    repeat (3) @(posedge clk);
    press(9'h01A, 1); if (k0 != 0) $fatal(1, "Z set %h", k0);
    press(9'h022, 1); if (k0 != 0) $fatal(1, "X set %h", k0);
    press(9'h016, 1); if (k0 != 32'h100) $fatal(1, "1 -> %h", k0);
    press(9'h02E, 1); if (k0 != 32'h300) $fatal(1, "5 -> %h", k0);
    press(9'h175, 1); press(9'h014, 1); if (k0 != 32'h318) $fatal(1, "up+ctrl -> %h", k0);
    press(9'h016, 0); press(9'h02E, 0); press(9'h175, 0); press(9'h014, 0); if (k0 != 0) $fatal(1, "release %h", k0);
    press(9'h006, 1); press(9'h04D, 1); if (k0 != 32'hC00) $fatal(1, "F2+P -> %h", k0);
    press(9'h024, 1); press(9'h01E, 1); if (k1 != 32'h100) $fatal(1, "E+2 -> %h", k1);
    $display("keys_tb PASS"); $finish;
  end
endmodule
