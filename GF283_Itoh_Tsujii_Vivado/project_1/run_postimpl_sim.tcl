#################################################################################
# run_postimpl_sim.tcl
#
# Mandatory deliverable: POST-IMPLEMENTATION TIMING SIMULATION of gf283_top.
#
#   vivado -mode batch -source run_postimpl_sim.tcl
#
# Run after build.tcl has completed implementation. Vivado exports the routed
# netlist plus its SDF delay annotation and simulates tb_gf283_top against it,
# so the transcript below is real gate-level, delay-annotated behaviour - not a
# behavioural RTL run.
#
# IF THIS SCRIPT FAILS with
#     ERROR: [Common 17-180] Spawn failed: Broken pipe
#     'compile.bat' is not recognized as an internal or external command
# the Vivado install is fine - the shell that launched it has
#     NoDefaultCurrentDirectoryInExePath=1
# which stops cmd.exe searching the current directory, and Vivado calls its
# generated .bat scripts bare. Clear that variable and retry:
#     Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
# The GUI's "Run Post-Implementation Timing Simulation" is unaffected.
#
# As a last resort, bypass launch_simulation entirely - this is what produced
# the shipped transcript:
#     powershell -ExecutionPolicy Bypass -File run_postimpl_sim.ps1
# It exports the same netlist and SDF and calls xvlog / xelab / xsim directly
# with the same switches.
#
# Transcript is written to
#   project_1.sim/sim_1/impl/timing/xsim/simulate.log
# and copied to  reports/post_impl_simulation.log
#################################################################################

set proj_dir [pwd]
open_project $proj_dir/project_1.xpr

set_property top     tb_gf283_top   [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

# Run until the testbench calls $finish rather than for a fixed wall time.
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# Keep the SDF timing checks switched on - the whole point of this run is to
# prove the design still functions with real post-route delays.
set_property -name {xsim.elaborate.xelab.more_options} \
             -value {-transport_int_delays -pulse_r 0 -pulse_int_r 0} \
             -objects [get_filesets sim_1]

# Set SHORT_RUN to 1 if the full vector set takes too long at gate level.
set SHORT_RUN 0
if {$SHORT_RUN} {
    set_property -name {xsim.simulate.xsim.more_options} \
                 -value {-testplusarg SHORT} -objects [get_filesets sim_1]
}

puts "\n===== LAUNCHING POST-IMPLEMENTATION TIMING SIMULATION =====\n"
launch_simulation -mode post-implementation -type timing

set simlog $proj_dir/project_1.sim/sim_1/impl/timing/xsim/simulate.log
if {[file exists $simlog]} {
    file mkdir $proj_dir/reports
    file copy -force $simlog $proj_dir/reports/post_impl_simulation.log
    puts "\n===== POST-IMPLEMENTATION SIMULATION TRANSCRIPT ====="
    set fh [open $simlog r]
    puts [read $fh]
    close $fh
} else {
    puts "WARNING: simulate.log not found at $simlog"
}

close_sim
close_project
puts "run_postimpl_sim.tcl finished."
