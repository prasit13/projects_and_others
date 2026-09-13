#################################################################################
# write_timing_netlist.tcl
#
# Exports the routed netlist and its SDF delay annotation for post-implementation
# TIMING simulation, without going through launch_simulation.
#
#   vivado -mode batch -source write_timing_netlist.tcl
#
# Why this exists
#   On some Windows installs Vivado's launch_simulation fails with
#       ERROR: [Common 17-180] Spawn failed: Broken pipe
#       'compile.bat' is not recognized as an internal or external command
#   because it invokes the generated .bat scripts without a path. Exporting the
#   netlist here and then calling xvlog / xelab / xsim explicitly (see
#   run_postimpl_sim.ps1) avoids that entirely and is otherwise identical.
#
# Outputs land in postimpl_sim/ :
#   gf283_top_time_impl.v     routed netlist, contains the $sdf_annotate call
#   gf283_top_time_impl.sdf   slow-corner delays for every cell and net
#################################################################################

set proj_dir [pwd]
set out_dir  $proj_dir/postimpl_sim
file mkdir $out_dir

open_checkpoint $proj_dir/project_1.runs/impl_1/gf283_top_routed.dcp

# -sdf_anno true makes the netlist call $sdf_annotate on the file below, so the
# two names must stay in step.
write_verilog -mode timesim -sdf_anno true -force $out_dir/gf283_top_time_impl.v
write_sdf     -mode timesim -process_corner slow -force $out_dir/gf283_top_time_impl.sdf

puts "\n=========================================================="
puts " Timing netlist exported to postimpl_sim/"
puts "   netlist : [file size $out_dir/gf283_top_time_impl.v] bytes"
puts "   sdf     : [file size $out_dir/gf283_top_time_impl.sdf] bytes"
puts " Next: run_postimpl_sim.ps1  (xvlog -> xelab -> xsim)"
puts "==========================================================\n"

close_design
