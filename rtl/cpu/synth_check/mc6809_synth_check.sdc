# Phase 0 criterion 4: what Fmax mc6809i reaches on its own, at this project's
# settings, and how much of the device it costs.
#
# clk_sys is 40 MHz: every Bally/Sente clock divides exactly out of it
# (docs/ROADMAP.md, "Clocks"), so 25 ns is the period the core must meet.
#
# Read output_files/*.sta.summary, not the Fitter's exit status: the Fitter
# reports success on a design that fails timing.
create_clock -name clk -period 25.000 [get_ports clk]
derive_clock_uncertainty

# ---------------------------------------------------------------------------
# The CPU advances only on cen_E, and cen_E is one clk in 32 (1.25 MHz from
# 40 MHz). Register-to-register paths inside the core therefore have 32 clocks
# to settle, not one. Without this the report is the Fmax of a 40 MHz 6809,
# which is not a machine that exists here.
#
# 8 is claimed rather than 31: it is a large margin over what the enable
# actually allows, and it leaves the constraint valid if the clock plan ever
# changes to a faster clk_sys or a shorter divider. Raising it further would
# stop the report saying anything useful.
#
# cen_Q, which samples the interrupt inputs, is also one in 32 and a half
# period away from cen_E, so it is covered by the same reasoning.
# ---------------------------------------------------------------------------
set cpu [get_registers {*mc6809i*}]
set_multicycle_path -setup -from $cpu -to $cpu 8
set_multicycle_path -hold  -from $cpu -to $cpu 7

# Harness only: the LFSR feeding the inputs and the XOR tree onto the result
# pin are not part of the core, and the input register is deliberately one
# cycle from the CPU.
set_false_path -to [get_keepers {result*}]
set_false_path -from [get_keepers {pat*}]
