# ##############################################################################
# run_postimpl_sim.ps1
#
# MANDATORY DELIVERABLE: post-implementation TIMING simulation of gf283_top.
#
#   powershell -ExecutionPolicy Bypass -File run_postimpl_sim.ps1
#
# Run after build.tcl has completed implementation.
#
# In the Vivado GUI, Run Post-Implementation Timing Simulation works normally and
# this script is unnecessary. It exists for terminal/script-driven runs, where
# launch_simulation can die with
#     ERROR: [Common 17-180] Spawn failed: Broken pipe
#     'compile.bat' is not recognized as an internal or external command
# That is not a broken install: Vivado calls its generated .bat scripts bare,
# relying on cmd.exe searching the current directory, and some shells set
# NoDefaultCurrentDirectoryInExePath=1 which disables that search. Clearing the
# variable usually fixes launch_simulation outright:
#     Remove-Item Env:NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
#
# This script sidesteps the issue entirely by calling xvlog -> xelab -> xsim
# directly, with exactly the switches Vivado's own generated scripts use, so the
# result is the same simulation.
#
# Transcript is written to  reports/post_impl_simulation.log
# ##############################################################################

$ErrorActionPreference = "Stop"

$VivadoBin = "C:\Xilinx\Vivado\2023.2\bin"
$ProjDir   = $PSScriptRoot
$SimDir    = Join-Path $ProjDir "postimpl_sim"
$Snapshot  = "gf283_top_time_impl"
$TbTop     = "tb_gf283_top"

# ---- 1. export the routed netlist + SDF -------------------------------------
Write-Host "`n[1/4] Exporting routed netlist and SDF ..." -ForegroundColor Cyan
Push-Location $ProjDir
& "$VivadoBin\vivado.bat" -mode batch -notrace -source write_timing_netlist.tcl `
    -log postimpl_netlist.log -journal postimpl_netlist.jou | Out-Null
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "netlist export failed - see postimpl_netlist.log" }
Pop-Location

# ---- 2. compile netlist + testbench -----------------------------------------
Write-Host "[2/4] xvlog: compiling netlist and testbench ..." -ForegroundColor Cyan
Push-Location $SimDir

# xsim needs a library mapping in the working directory
"xil_defaultlib=xsim.dir/xil_defaultlib" | Out-File -Encoding ascii xsim.ini

@"
# Post-implementation timing simulation sources
verilog xil_defaultlib "$Snapshot.v"
verilog xil_defaultlib "../project_1.srcs/sim_1/new/tb_gf283_top.v"
nosort
"@ | Out-File -Encoding ascii "$TbTop`_vlog.prj"

& "$VivadoBin\xvlog.bat" --relax -prj "$TbTop`_vlog.prj" -log xvlog.log
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xvlog failed - see $SimDir\xvlog.log" }

# ---- 3. elaborate with SDF annotation ---------------------------------------
# --maxdelay selects the slow-corner (worst-case) delays, which is what the
# setup analysis in report_timing_summary signed off against.
# The -pulse_* switches disable glitch filtering so nothing is hidden.
Write-Host "[3/4] xelab: elaborating with SDF annotation (this takes a while) ..." -ForegroundColor Cyan
& "$VivadoBin\xelab.bat" --debug typical --relax --mt 2 --maxdelay `
    -L xil_defaultlib -L simprims_ver -L secureip `
    --snapshot $Snapshot `
    -transport_int_delays -pulse_r 0 -pulse_int_r 0 -pulse_e 0 -pulse_int_e 0 `
    xil_defaultlib.$TbTop xil_defaultlib.glbl -log elaborate.log
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "xelab failed - see $SimDir\elaborate.log" }

# ---- 4. run -----------------------------------------------------------------
Write-Host "[4/4] xsim: running post-implementation timing simulation ..." -ForegroundColor Cyan
# log_wave populates the .wdb; without it the wave window opens empty.
# Scope it to the testbench (top-level ports) - logging the whole netlist
# recursively would produce a multi-GB database.
"log_wave /tb_gf283_top/*`nrun all`nquit`n" | Out-File -Encoding ascii runsim.tcl
& "$VivadoBin\xsim.bat" $Snapshot -tclbatch runsim.tcl -log simulate.log
$simExit = $LASTEXITCODE
Pop-Location

# ---- collect the transcript --------------------------------------------------
$reports = Join-Path $ProjDir "reports"
New-Item -ItemType Directory -Force -Path $reports | Out-Null
Copy-Item (Join-Path $SimDir "simulate.log") (Join-Path $reports "post_impl_simulation.log") -Force

Write-Host "`n===== POST-IMPLEMENTATION SIMULATION TRANSCRIPT =====" -ForegroundColor Green
Get-Content (Join-Path $SimDir "simulate.log")

if ($simExit -ne 0) { throw "xsim exited with code $simExit" }
Write-Host "`nTranscript saved to reports\post_impl_simulation.log" -ForegroundColor Green
