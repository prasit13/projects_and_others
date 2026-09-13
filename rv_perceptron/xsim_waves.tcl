#==========================================================================
# xsim_waves.tcl -- pre-built waveform layout for the Vivado simulator.
#
# Hook it in with:
#   Simulation Settings -> Simulation tab -> xsim.simulate.custom_tcl
#   set to the full path of this file.
#
# Vivado hands this file to xsim as its -tclbatch script, which REPLACES the
# cmd.tcl it would otherwise generate. Two consequences:
#
#   * it runs after the design is loaded but before any simulation time has
#     elapsed, so every signal below is logged from time 0 and arrives already
#     grouped with a sensible radix; but
#   * the `run` normally supplied by cmd.tcl is gone, so this file has to
#     issue it -- see the bottom. Without that the kernel loads and sits at
#     0 fs with an empty wave window. The "XSim simulation ran for all"
#     message is not evidence to the contrary: it only echoes the
#     xsim.simulate.runtime property, whatever actually happened.
#
# Signals that do not exist in the current predictor configuration (the
# perceptron internals when you build gshare, say) are skipped with a note
# rather than aborting the script, so the same file works for all four.
#==========================================================================

# Vivado's add_wave takes its own radix names, NOT the GTKWave/generic ones.
# Valid: default dec bin oct hex unsigned ascii smag -- "binary" and "signed"
# are rejected. Done as a switch inside the proc rather than a top-level
# array: xsim sources this file in a scope where a script-level array is not
# reachable through `global` from inside a proc.
proc rdx {r} {
  switch -- $r {
    binary   -
    bin      { return bin }
    signed   -
    dec      { return dec }
    unsigned { return unsigned }
    ascii    { return ascii }
    octal    -
    oct      { return oct }
    hex      { return hex }
    default  { return hex }
  }
}

# helper: add one signal, reporting the real reason if it fails.
# Probe with get_objects first: calling add_wave on a name that does not
# exist raises a Vivado ERROR (and a Critical Messages dialog) even when the
# Tcl error itself is caught. The list below deliberately covers both
# predictor builds, so a few names are always absent and that is not a fault.
proc wv {grp path {radix hex} {label ""}} {
  if {$path eq ""} { return }
  if {[llength [get_objects -quiet $path]] == 0} {
    puts "  \[waves\] absent (other predictor build): $path"
    return
  }
  if {[catch {
    if {$label eq ""} {
      add_wave -into $grp -radix [rdx $radix] $path
    } else {
      add_wave -into $grp -radix [rdx $radix] -name $label $path
    }
  } err]} {
    puts "  \[waves\] FAILED $path : $err"
  }
}

# The predictor lives inside a generate block, and the exact hierarchical
# name of that scope is not something to guess -- Vivado spells generate
# scopes differently in different contexts (synthesis showed it as
# "\gPerceptron.bPredict"). Probe for it, and print the scope tree so the
# real name is visible if none of the candidates match.
proc find_scope {candidates} {
  foreach c $candidates {
    if {[llength [get_scopes -quiet $c]] > 0} { return $c }
  }
  return ""
}

puts "\n\[waves\] scopes under /TB/uut :"
foreach s [get_scopes -quiet /TB/uut/*] { puts "      $s" }

set BP [find_scope [list \
  /TB/uut/gPerceptron/bPredict \
  /TB/uut/gClassic/bPredict \
  {/TB/uut/gPerceptron.bPredict} \
  {/TB/uut/gClassic.bPredict} \
  /TB/uut/bPredict ]]

if {$BP eq ""} {
  puts "\[waves\] could not locate the predictor scope -- groups 3/4/6/8 will"
  puts "\[waves\] be thin. Use the list above to find its real name.\n"
} else {
  puts "\[waves\] predictor scope: $BP\n"
}

# sub-scope holding the N4 override registers (only in the perceptron build)
set OV ""
if {$BP ne ""} { set OV [find_scope [list $BP/gOvr]] }

puts "\n\[waves\] building grouped wave layout ..."

# start from a clean window so relaunches do not stack duplicates
catch { remove_wave -of [get_wave_config] [get_waves *] }

#--------------------------------------------------------------- 1. clock
set g [add_wave_group "1 - Clock / reset"]
wv $g /TB/clk          binary
wv $g /TB/rst          binary
wv $g /TB/usePredictor binary

#--------------------------------------------------------------- 2. fetch
set g [add_wave_group "2 - Fetch"]
wv $g /TB/uut/fetch/pc          hex      "pc"
wv $g /TB/uut/F_instr           hex      "instr"
wv $g /TB/uut/F_pcPlus4         hex      "pc+4"
wv $g /TB/uut/P_bPredictTaken   binary   "predictTaken (fast)"
wv $g /TB/uut/P_btbTarget       hex      "btbTarget"
wv $g /TB/uut/H_stallF          binary   "stallF"

#------------------------------------------- 3. predictor, fetch-side path
# The fast path that actually steers fetch: BTB hit + 2-bit counter.
# $BP is discovered above rather than hard-coded, so this works for the
# perceptron and the classic builds alike.
set g [add_wave_group "3 - Predict (fetch, fast path)"]
if {$BP ne ""} {
  wv $g $BP/fBtbHit     binary   "btbHit"
  wv $g $BP/fPredTaken  binary   "predTaken"
  wv $g $BP/ghrSpec     binary   "ghrSpec (N1)"
  # perceptron-only
  wv $g $BP/fUncond     binary   "isJump"
  wv $g $BP/fBimTaken   binary   "bimodalTaken"
  wv $g $BP/fPercIdx    unsigned "percIdx"
  wv $g $BP/theta       signed   "theta (N2)"
  # classic-only
  wv $g $BP/fPhtIdx     unsigned "phtIdx"
}

#------------------------------------------------- 4. N4 override (decode)
# The perceptron's verdict, one cycle later, overruling the fast prediction.
set g [add_wave_group "4 - N4 override (decode)"]
if {$OV ne ""} {
  wv $g $OV/yD          signed "y (dot product)"
  wv $g $OV/dFastTaken  binary "fast said"
  wv $g $OV/dFinalTaken binary "perceptron says"
  wv $g $OV/dUseBim     binary "N3 gate fired"
}
wv $g /TB/uut/P_ovrValid  binary "OVERRIDE"
wv $g /TB/uut/P_ovrTaken  binary "ovrTaken"
wv $g /TB/uut/P_ovrTarget hex    "ovrTarget"

#--------------------------------------------- 5. execute, branch resolves
set g [add_wave_group "5 - Execute (resolution)"]
wv $g /TB/uut/E_pc           hex    "exPc"
wv $g /TB/uut/E_branch       binary "isBranch"
wv $g /TB/uut/E_controlXfer  binary "isCtrlXfer"
wv $g /TB/uut/E_btbUpdate    binary "resolvedTaken"
wv $g /TB/uut/E_wrongBranch  binary "MISPREDICT"
wv $g /TB/uut/E_pcTarget     hex    "redirectTo"

#--------------------------------------------- 6. training, one cycle later
set g [add_wave_group "6 - Train (EX+1)"]
if {$BP ne ""} {
  wv $g $BP/tValid     binary   "trainValid"
  wv $g $BP/tTaken     binary   "outcome"
  wv $g $BP/tIdx       unsigned "row"
  wv $g $BP/yT         signed   "y recomputed"
  wv $g $BP/tPercWrong binary   "perceptron wrong"
  wv $g $BP/tDoTrain   binary   "UPDATE WEIGHTS"
  wv $g $BP/ghrArch    binary   "ghrArch (N1)"
}

#--------------------------------------------------- 7. pipeline control
set g [add_wave_group "7 - Hazard / pipeline"]
wv $g /TB/uut/H_stallD binary
wv $g /TB/uut/H_flushD binary
wv $g /TB/uut/H_flushE binary
wv $g /TB/uut/H_fwdAE  unsigned
wv $g /TB/uut/H_fwdBE  unsigned

#------------------------------------------------------ 8. live statistics
# Plain `integer` counters, which xsim does add to the wave window (they only
# need --debug typical, which the project already sets). Watching these step
# is the quickest way to see *when* a misprediction or an override happened;
# the final totals are printed to the Tcl console by TB.sv at $finish.
set g [add_wave_group "8 - Statistics (live)"]
if {$BP ne ""} {
  wv $g $BP/st_branches unsigned "branches"
  wv $g $BP/st_mispred  unsigned "mispredicts"
  wv $g $BP/st_override unsigned "overrides"
  wv $g $BP/st_btbMiss  unsigned "btbMisses"
}
wv $g /TB/cycles unsigned "cycle count"

#----------------------------------------------------------- 9. UART out
set g [add_wave_group "9 - UART"]
wv $g /TB/uartWen  binary
wv $g /TB/uartData ascii "char"

puts "\[waves\] done -- 9 groups\n"

#--------------------------------------------------------------------------
# Run. Required: as -tclbatch this file stands in for the generated cmd.tcl,
# so nothing else will start the simulation.
#
# `run all` goes to the $finish in TB.sv, which is what prints the RESULT
# block -- the same end point the iverilog flow reaches. No `quit` after it:
# in the GUI that would tear the simulation down and take the waveform with
# it. Batch users should append their own.
#--------------------------------------------------------------------------
puts "\[waves\] running to \$finish ...\n"
run all
