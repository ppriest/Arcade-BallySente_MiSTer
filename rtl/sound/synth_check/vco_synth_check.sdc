# 40 MHz clk_sys. Like the filter, the oscillator runs real clk_sys cycles --
# 51 of them per sample in the worst case measured by sim/cem3394_vco_tb -- so
# there is no clock-enable multicycle to claim.
create_clock -name clk -period 25.000 [get_ports clk]
derive_clock_uncertainty
set_false_path -to [get_keepers {result*}]
set_false_path -from [get_keepers {pat*}]
