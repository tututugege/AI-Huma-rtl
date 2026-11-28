#!/usr/bin/env bash
# Tier 2a: Synopsys DC Fast Mode (dc-ultra-relax | dc-ultra-fast | dc-low | dc-med | dc-low-relax)
# Usage: run_tier2_dc_fast.sh <module> <sram_mode: real|bb|none> <effort_mode> <clk_ns> <unc_ns> <io_ns> <out_dir> [cores] [rtl_root]
set -uo pipefail

M=$1
SRAM_MODE=${2:-real}
EFFORT=${3:-dc-low}
CLK_NS=${4:-0.65}
UNC_NS=${5:-0.05}
IO_NS=${6:-0.12}
OUT=$7
CORES=${8:-16}
RTL_ROOT=${9:-/nfs_global/S/houruyao/fast_ppa_eval}

source /eda-tools/modulefiles/init.sh 2>/dev/null || true
export PATH="/eda-tools/synopsys/syn/W-2024.09-SP2/bin:$PATH"

STD_DB_SVT="/eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140_180a/tcbn28hpcplusbwp12t40p140ssg0p81v125c.db"
STD_DB_LVT="/eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140lvt_180a/tcbn28hpcplusbwp12t40p140lvtssg0p81v125c.db"
SRAM_DB_DIR="/nfs_global/S/houruyao/tsmc28_sram_db"

SRAM_LIBS_TCL=""
if [ "$SRAM_MODE" = "real" ]; then
  SRAM_LIBS_TCL="tem5n28hpcplvta128x64m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta256x32m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta256x64m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta256x72m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta512x72m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta512x8m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta64x32m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta64x58m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta64x64m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta64x72m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta1024x32m4swso_110a_ssg0p81v125c.db"
fi

DEFS="{SYNTHESIS}"
if [ "$SRAM_MODE" = "real" ]; then
  DEFS="{SYNTHESIS SYNTH_TSMC28_SRAM}"
elif [ "$SRAM_MODE" = "bb" ]; then
  DEFS="{SYNTHESIS SRAM_BLACKBOX}"
fi

OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"
WORK="/tmp/tier2a_${M}_${EFFORT}_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

if [[ "$M" != soc_* && "$M" != "chip_top" ]]; then
  grep -v '/rtl/soc/' "$RTL_ROOT/files.f" > "$WORK/files.f"
else
  cp "$RTL_ROOT/files.f" "$WORK/files.f"
fi

PRE_COMPILE_TCL=""
RETIME_AFTER=0
if [ "$EFFORT" = "dc-ultra-relax" ]; then
  COMPILE_CLK="5.00"
  COMPILE_CMD="compile_ultra -no_autoungroup -no_boundary_optimization -no_design_rule"
  RETIME_AFTER=1
elif [ "$EFFORT" = "dc-ultra-fast" ]; then
  COMPILE_CLK="$CLK_NS"
  COMPILE_CMD="compile_ultra -no_autoungroup -no_boundary_optimization -no_design_rule"
elif [ "$EFFORT" = "dc-low" ]; then
  COMPILE_CLK="$CLK_NS"
  COMPILE_CMD="compile -map_effort low -area_effort none"
elif [ "$EFFORT" = "dc-med" ]; then
  COMPILE_CLK="$CLK_NS"
  COMPILE_CMD="compile -map_effort medium -area_effort none"
elif [ "$EFFORT" = "dc-low-relax" ]; then
  COMPILE_CLK="2.00"
  COMPILE_CMD="compile -map_effort low -area_effort none"
  RETIME_AFTER=1
else
  echo "ERROR: unknown effort_mode $EFFORT" >&2
  exit 1
fi

RETIME_CMD=""
if [ "$RETIME_AFTER" -eq 1 ]; then
  RETIME_CMD="apply_sdc $CLK_NS $UNC_NS $IO_NS
update_timing"
fi

cat > "$WORK/run.tcl" <<TCL
set_host_options -max_cores $CORES
define_design_lib WORK -path $WORK/WORK
set search_path [list \
  /eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140_180a \
  /eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140lvt_180a \
  $SRAM_DB_DIR]
set target_library [list tcbn28hpcplusbwp12t40p140ssg0p81v125c.db tcbn28hpcplusbwp12t40p140lvtssg0p81v125c.db]
set sram_libs [list $SRAM_LIBS_TCL]
set link_library [concat * \$target_library \$sram_libs]

set fp [open "$WORK/files.f" r]
set flist [split [string trim [read \$fp]] "\n"]
close \$fp

set t_start [clock seconds]
analyze -format sverilog -define $DEFS \$flist
elaborate $M
current_design $M
set ls [link]
puts "DC_LINK_STATUS=\$ls"
set t_elab [expr {[clock seconds] - \$t_start}]
puts "DC_ELAB_SEC=\$t_elab"

proc apply_sdc {per unc io} {
  if {[sizeof_collection [get_clocks -quiet clk]] > 0} {
    remove_clock [get_clocks -quiet clk]
  }
  set clk_port [get_ports -quiet clk]
  if {[sizeof_collection \$clk_port] > 0} {
    create_clock -name clk -period \$per \$clk_port
    set_clock_uncertainty \$unc [get_clocks clk]
    set_input_delay \$io -clock clk [remove_from_collection [all_inputs] \$clk_port]
    set_output_delay \$io -clock clk [all_outputs]
  }
  set rst_port [get_ports -quiet rst_n]
  if {[sizeof_collection \$rst_port] > 0} {
    set_false_path -from \$rst_port
  }
}

apply_sdc $COMPILE_CLK $UNC_NS $IO_NS
$PRE_COMPILE_TCL

set t_c0 [clock seconds]
$COMPILE_CMD
set t_comp [expr {[clock seconds] - \$t_c0}]
puts "DC_COMPILE_SEC=\$t_comp"

$RETIME_CMD

write -format ddc -hierarchy -output $OUT/$M.ddc
report_qor > $OUT/qor.rpt
report_area -hierarchy > $OUT/area.rpt
report_timing -delay_type max -max_paths 10 -input_pins -nets -nosplit > $OUT/timing_max.rpt
report_timing -delay_type max -from [all_registers -clock_pins] -to [all_registers -data_pins] -max_paths 10 -input_pins -nosplit > $OUT/timing_reg2reg.rpt

set t_tot [expr {[clock seconds] - \$t_start}]
puts "DC_TOTAL_SEC=\$t_tot"
quit
TCL

ALIB_SEED="/nfs_global/S/houruyao/dc28_v11/out/front_top_v11_opt_065ns/alib-52"
[ -d "$ALIB_SEED" ] && cp -r "$ALIB_SEED" "$WORK/alib-52"
echo "[$(date +%T)] $(hostname -s) Tier2a START $M ($EFFORT mode=$SRAM_MODE clk=${CLK_NS}ns cores=$CORES)"
t0=$(date +%s)
(cd "$WORK" && dc_shell -f "$WORK/run.tcl") > "$OUT/dc.log" 2>&1
rc=$?
t1=$(date +%s)

if [ $rc -ne 0 ] || [ ! -s "$OUT/qor.rpt" ]; then
  echo "ERROR: dc_shell failed (rc=$rc) for $M ($EFFORT)"
  tail -n 30 "$OUT/dc.log"
  exit 1
fi

echo "TIER2A_DONE mod=$M effort=$EFFORT mode=$SRAM_MODE wall=$((t1-t0))s" > "$OUT/timing_summary.txt"
grep -E "DC_LINK_STATUS|DC_ELAB_SEC|DC_COMPILE_SEC|DC_TOTAL_SEC|Elapsed time|Memory usage" "$OUT/dc.log" >> "$OUT/timing_summary.txt" || true
grep -E "Critical Path|Total Negative|Leaf Cell|Combinational Area|Noncombinational Area|Macro/Black Box|Cell Area:" "$OUT/qor.rpt" >> "$OUT/timing_summary.txt" || true
grep -E "Number of macros/black boxes" "$OUT/area.rpt" >> "$OUT/timing_summary.txt" || true
cat "$OUT/timing_summary.txt"
