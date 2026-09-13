#################################################################################
# Constraints : gf283_top
# Project     : GF(2^283) arithmetic core  (HW Security Assignment 1)
# Device      : xc7a100tcsg324-1  (Digilent Arty A7-100)
#
# The design is a compute core, not a board-level design: it is taken through
# synthesis, place and route and post-implementation timing simulation, but no
# bitstream is produced. Pin locations are therefore left unconstrained and the
# placer assigns the 75 top-level I/O automatically.
#
# NOTE ON I/O BUDGET
#   The earlier flat 283-bit interface needed 570 pins against the 210 available
#   on this package, which is what produced
#       [Place 30-415] IO Placement failed due to overutilization.
#   gf283_top streams operands 32 bits at a time, so the pin count is now 75.
#################################################################################

# ---- primary clock -------------------------------------------------------
# 20 ns = 50 MHz. This matches the period the design closes timing at; keep the
# testbench CLK_PERIOD in tb_gf283_top.v equal to (or larger than) this value or
# post-implementation timing simulation will report genuine setup violations.
create_clock -period 20.000 -name sys_clk -waveform {0.000 10.000} [get_ports clk]

# ---- asynchronous reset --------------------------------------------------
# rst_n is asserted asynchronously but released synchronously by the testbench,
# so its (very high fan-out) path is not timed against sys_clk.
set_false_path -from [get_ports rst_n]

# ---- I/O timing contract -------------------------------------------------
# These two numbers are a CONTRACT WITH THE TESTBENCH and must stay in step
# with T_DRIVE / T_SAMPLE in tb_gf283_top.v:
#
#   set_input_delay 4.0   <->  the bench launches inputs 4 ns after a rising
#                              edge, leaving the design 16 ns to capture them.
#   set_output_delay 4.0  <->  outputs must be stable 4 ns before the next
#                              rising edge, i.e. within 16 ns of clock-to-out;
#                              the bench samples them at 16 ns.
#
# Getting this wrong is not academic. An earlier version declared 5.0 ns of
# input delay (promising the design 15 ns) while the bench drove inputs on the
# falling edge (actually giving only 10 ns). Vivado met the constraint it was
# given, but in_valid and out_ready route in 11.4 ns and 10.4 ns to all 288
# shift-register flops, so post-implementation timing simulation captured stale
# data on those two enables and reported corrupted results. Behavioural
# simulation, having no delays, could not expose it.
set_input_delay  -clock sys_clk 4.000 [get_ports {start op in_valid in_word[*] out_ready}]
set_output_delay -clock sys_clk 4.000 [get_ports {in_ready out_valid out_word[*] busy done err_zero}]

# ---- configuration bank voltage -----------------------------------------
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
