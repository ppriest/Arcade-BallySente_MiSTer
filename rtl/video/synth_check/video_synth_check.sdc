# 40 MHz clk_sys. The video path runs real clk_sys cycles -- the pixel phase is
# a counter tap, not a clock enable that gates the logic -- so there is no
# multicycle to claim and this is the honest constraint.
create_clock -name clk -period 25.000 [get_ports clk]
derive_clock_uncertainty
set_false_path -to [get_keepers {result*}]
set_false_path -from [get_keepers {pat*}]
