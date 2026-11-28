#!/usr/bin/env bash
# Tier 2b: Synopsys DC Bottom-Up Incremental .ddc Assembly for front_top
# Reuses pre-compiled bpu.ddc and icache.ddc, sets dont_touch on them,
# and compiles only the front_top glue logic.
# Usage: run_tier2b_dc_inc.sh <bpu_ddc> <icache_ddc> <clk_ns> <unc_ns> <io_ns> <out_dir> [cores] [rtl_root]
set -uo pipefail

BPU_DDC=$1
ICACHE_DDC=$2
CLK_NS=${3:-0.65}
UNC_NS=${4:-0.05}
IO_NS=${5:-0.12}
OUT=$6
CORES=${7:-16}
RTL_ROOT=${8:-/nfs_global/S/houruyao/fast_ppa_eval}

source /eda-tools/modulefiles/init.sh 2>/dev/null || true
export PATH="/eda-tools/synopsys/syn/W-2024.09-SP2/bin:$PATH"

STD_DB_SVT="/eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140_180a/tcbn28hpcplusbwp12t40p140ssg0p81v125c.db"
STD_DB_LVT="/eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140lvt_180a/tcbn28hpcplusbwp12t40p140lvtssg0p81v125c.db"
SRAM_DB_DIR="/nfs_global/S/houruyao/tsmc28_sram_db"

SRAM_LIBS_TCL="tem5n28hpcplvta128x64m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta256x32m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta256x64m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta256x72m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta512x72m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta512x8m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta64x32m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta64x58m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta64x64m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta64x72m4swso_110a_ssg0p81v125c.db tem5n28hpcplvta1024x32m4swso_110a_ssg0p81v125c.db"

if [ ! -f "$BPU_DDC" ] || [ ! -f "$ICACHE_DDC" ]; then
  echo "ERROR: missing input ddc: $BPU_DDC or $ICACHE_DDC" >&2
  exit 1
fi

BPU_DDC="$(cd "$(dirname "$BPU_DDC")" && pwd)/$(basename "$BPU_DDC")"
ICACHE_DDC="$(cd "$(dirname "$ICACHE_DDC")" && pwd)/$(basename "$ICACHE_DDC")"
OUT="$(mkdir -p "$OUT" && cd "$OUT" && pwd)"
WORK="/tmp/tier2b_front_top_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# Exclude rtl/soc/ and non-package RTL under bpu/ and icache/ so DC links bpu & icache from .ddc
python3 -c "
for line in open('$RTL_ROOT/files.f'):
    s = line.strip()
    if not s or '/rtl/soc/' in s:
        continue
    if ('/frontend/bpu/' in s or '/frontend/icache/' in s) and not s.endswith('_pkg.sv'):
        continue
    print(s)
" > "$WORK/glue_files.f"

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

set t_start [clock seconds]
read_ddc $BPU_DDC
read_ddc $ICACHE_DDC
set preloaded_designs [get_designs *]
puts "PRELOADED_DESIGNS=[get_object_name \$preloaded_designs]"
set_dont_touch \$preloaded_designs

set fp [open "$WORK/glue_files.f" r]
set flist [split [string trim [read \$fp]] "\n"]
close \$fp

analyze -format sverilog -define {SYNTHESIS SYNTH_TSMC28_SRAM} \$flist
elaborate front_top
current_design front_top
set ls [link]
puts "DC_LINK_STATUS=\$ls"

set_dont_touch [get_designs {bpu icache}]
set_dont_touch [get_cells -quiet {u_icache u_pred_path/u_bpu}]
set t_elab [expr {[clock seconds] - \$t_start}]
puts "DC_ELAB_SEC=\$t_elab"

set clk_port [get_ports -quiet clk]
create_clock -name clk -period $CLK_NS \$clk_port
set_clock_uncertainty $UNC_NS [get_clocks clk]
set_input_delay $IO_NS -clock clk [remove_from_collection [all_inputs] \$clk_port]
set_output_delay $IO_NS -clock clk [all_outputs]
set_false_path -from [get_ports -quiet rst_n]

set t_c0 [clock seconds]
compile_ultra -no_autoungroup -no_boundary_optimization -no_design_rule
set t_comp [expr {[clock seconds] - \$t_c0}]
puts "DC_COMPILE_SEC=\$t_comp"

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
echo "[$(date +%T)] $(hostname -s) Tier2b START front_top incremental (clk=${CLK_NS}ns cores=$CORES)"
t0=$(date +%s)
(cd "$WORK" && dc_shell -f "$WORK/run.tcl") > "$OUT/dc.log" 2>&1
rc=$?
t1=$(date +%s)

if [ $rc -ne 0 ] || [ ! -s "$OUT/qor.rpt" ]; then
  echo "ERROR: dc_shell incremental failed (rc=$rc)"
  tail -n 30 "$OUT/dc.log"
  exit 1
fi

echo "TIER2B_DONE mod=front_top_inc wall=$((t1-t0))s" > "$OUT/timing_summary.txt"
grep -E "DC_LINK_STATUS|DC_ELAB_SEC|DC_COMPILE_SEC|DC_TOTAL_SEC|Elapsed time|Memory usage" "$OUT/dc.log" >> "$OUT/timing_summary.txt" || true
grep -E "Critical Path|Total Negative|Leaf Cell|Combinational Area|Noncombinational Area|Macro/Black Box|Cell Area:" "$OUT/qor.rpt" >> "$OUT/timing_summary.txt" || true
grep -E "Number of macros/black boxes" "$OUT/area.rpt" >> "$OUT/timing_summary.txt" || true
cat "$OUT/timing_summary.txt"
