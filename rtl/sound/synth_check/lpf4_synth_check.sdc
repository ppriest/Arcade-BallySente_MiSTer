# 40 MHz clk_sys. The filter runs twelve cycles per sample at 96 kHz per voice,
# so unlike the CPU it has no clock-enable multicycle to claim: every one of
# those cycles is a real clk_sys cycle and the path must close at 25 ns.
create_clock -name clk -period 25.000 [get_ports clk]
derive_clock_uncertainty
set_false_path -to [get_keepers {result*}]
set_false_path -from [get_keepers {pat*}]
