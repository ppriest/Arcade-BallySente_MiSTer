create_clock -name clk -period 25.000 [get_ports clk]
derive_clock_uncertainty
set_false_path -to [get_keepers {result*}]
set_false_path -from [get_keepers {pat*}]
