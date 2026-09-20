# What mc6809i would reach if it had to advance on EVERY clk, i.e. with the
# cen_E multicycle removed. The real design does not, but this is the number
# that says how much headroom the core itself has.
project_open mc6809_synth_check -revision mc6809_synth_check
create_timing_netlist
read_sdc noexcept.sdc
update_timing_netlist
set r [get_clock_fmax_info]
foreach x $r { post_message -type info "FMAX_NOEXC [lindex $x 0] [lindex $x 1] MHz restricted [lindex $x 2]" }
project_close
