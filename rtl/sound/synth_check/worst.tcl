project_open lpf4_synth_check -revision lpf4_synth_check
create_timing_netlist -model slow -temperature -40 -voltage 1100
read_sdc lpf4_synth_check.sdc
update_timing_netlist
set paths [get_timing_paths -setup -npaths 3 -detail path_only]
foreach_in_collection p $paths {
    post_message -type info [format "SLACK %s  FROM %s  TO %s" \
        [get_path_info $p -slack] \
        [get_node_info [get_path_info $p -from] -name] \
        [get_node_info [get_path_info $p -to] -name]]
}
project_close
