# Worst setup and hold slack for every clock at every operating corner, from
# the existing post-fit netlist. The .qsf turns multicorner analysis off, so
# the build's own summary is the slow corner only. Run from the directory
# holding the database:
#   quartus_sta -t ../scripts/sta_corners.tcl <revision>
set rev [lindex $quartus(args) 0]
project_open $rev
create_timing_netlist
read_sdc
update_timing_netlist
foreach corner [get_available_operating_conditions] {
    set_operating_conditions $corner
    update_timing_netlist
    foreach kind {setup hold} {
        foreach_in_collection clk [all_clocks] {
            set name [get_clock_info -name $clk]
            set r [report_timing -$kind -to_clock $name -npaths 1 -nworst 1 -detail summary -panel_name tmp]
            set slack [lindex $r 1]
            if {[lindex $r 0] > 0} {
                puts [format "%-22s %-5s %8.3f  %s" $corner $kind $slack $name]
            }
        }
    }
}
project_close -dont_export_assignments
