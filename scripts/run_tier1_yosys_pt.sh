#!/usr/bin/env bash
# Tier 1: Yosys (TSMC28 LVT + optional real TSMC28 SRAM macros) -> Synopsys PrimeTime real STA
# Usage: run_tier1_yosys_pt.sh <module> <sram_mode: real|bb|none> <clk_ns> <unc_ns> <io_ns> <out_dir> [rtl_root]
set -uo pipefail

M=$1
SRAM_MODE=${2:-real}
CLK_NS=${3:-0.65}
UNC_NS=${4:-0.05}
IO_NS=${5:-0.12}
OUT=$6
RTL_ROOT=${7:-/nfs_global/S/houruyao/fast_ppa_eval}

export PATH="/nfs_global/S/houruyao/tools/oss-cad-suite/bin:$PATH"
SLANG="/nfs_global/S/houruyao/tools/oss-cad-suite/share/yosys/plugins/slang.so"
source /eda-tools/modulefiles/init.sh 2>/dev/null || true
export PATH="/eda-tools/synopsys/prime/W-2024.09-SP2/bin:$PATH"

STD_LIB_LVT="/eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140lvt_180a/tcbn28hpcplusbwp12t40p140lvtssg0p81v125c.lib"
STD_DB_SVT="/eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140_180a/tcbn28hpcplusbwp12t40p140ssg0p81v125c.db"
STD_DB_LVT="/eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140lvt_180a/tcbn28hpcplusbwp12t40p140lvtssg0p81v125c.db"
SRAM_LIB_BASE="/eda-tools/pdk/TSMC28/sram/Front_End/timing_power_noise/NLDM/temn28hpcphssrammacros_110a"
SRAM_DB_DIR="/nfs_global/S/houruyao/tsmc28_sram_db"

SRAM_MACROS=(
  tem5n28hpcplvta128x64m4swso_110a
  tem5n28hpcplvta256x32m4swso_110a
  tem5n28hpcplvta256x64m4swso_110a
  tem5n28hpcplvta256x72m4swso_110a
  tem5n28hpcplvta512x72m4swso_110a
  tem5n28hpcplvta512x8m4swso_110a
  tem5n28hpcplvta64x32m4swso_110a
  tem5n28hpcplvta64x58m4swso_110a
  tem5n28hpcplvta64x64m4swso_110a
  tem5n28hpcplvta64x72m4swso_110a
  tem5n28hpcplvta1024x32m4swso_110a
)

mkdir -p "$OUT"
WORK="/tmp/tier1_${M}_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

FILES_F="$RTL_ROOT/files.f"
if [ ! -f "$FILES_F" ]; then
  echo "ERROR: missing $FILES_F" >&2
  exit 1
fi
FILES=$(tr "\n" " " < "$FILES_F")
CLK_PS=$(python3 -c "print(int(round(float('$CLK_NS') * 1000.0)))")

SRAM_READ=""
SRAM_STAT=""
SRAM_DBS=""
SLANG_DEFS="-DSYNTHESIS"
if [ "$SRAM_MODE" = "real" ]; then
  SLANG_DEFS="-DSYNTHESIS -DSYNTH_TSMC28_SRAM"
  for sm in "${SRAM_MACROS[@]}"; do
    lf="$SRAM_LIB_BASE/$sm/${sm}_ssg0p81v125c.lib"
    df="$SRAM_DB_DIR/${sm}_ssg0p81v125c.db"
    if [ ! -f "$lf" ] || [ ! -f "$df" ]; then
      echo "ERROR: missing SRAM lib/db for $sm" >&2
      exit 1
    fi
    SRAM_READ+="read_liberty -lib $lf"$'\n'
    SRAM_STAT+=" -liberty $lf"
    SRAM_DBS+=" $df"
  done
elif [ "$SRAM_MODE" = "bb" ]; then
  SLANG_DEFS="-DSYNTHESIS -DSRAM_BLACKBOX"
fi

# ABC script: balance + timing-driven map + PI/FF-Q & internal bounded-fanout buffering + sizing (NO buffer -c)
ABC_SCRIPT=${TIER1_ABC_SCRIPT:-"+strash;balance;map,-D,${CLK_PS};topo;buffer,-p,-N,16,-S,80;upsize,-D,${CLK_PS};dnsize,-D,${CLK_PS}"}

cat > "$WORK/abc.constr" <<CONSTR
set_driving_cell BUFFD1BWP12T40P140LVT
set_load 2.0
CONSTR

cat > "$WORK/$M.ys" <<YS
${SRAM_READ}
read_slang --top $M --keep-hierarchy --unroll-limit 100000 -Wno-error=index-oob $SLANG_DEFS $FILES
hierarchy -check -top $M
proc
flatten
opt_expr
opt_clean
opt -nodffe -nosdff
fsm
opt
wreduce
peepopt
opt_clean
alumacc
opt
opt_mem
opt_mem_feedback
memory_bmux2rom
memory_dff
opt_clean
memory_share
opt_mem_widen
memory_collect
opt_clean
memory_map
opt -fast -full
opt -full
techmap -map +/choices/kogge-stone.v -map +/techmap.v
opt_clean -purge
dfflegalize -cell \$_DFF_P_ 01 -cell \$_DFF_PN0_ 01 -cell \$_DFF_PN1_ 01
opt_expr
opt_clean
techmap
opt_expr
opt_clean
dfflibmap -liberty $STD_LIB_LVT
abc -D $CLK_PS -liberty $STD_LIB_LVT -constr $WORK/abc.constr -script $ABC_SCRIPT
setundef -zero -undriven
opt_clean -purge
splitnets
tee -o $OUT/$M.stat stat -liberty $STD_LIB_LVT $SRAM_STAT
write_verilog -noattr -noexpr -nohex -simple-lhs $WORK/$M.mapped.v
YS

echo "[$(date +%T)] $(hostname -s) Tier1 START $M (mode=$SRAM_MODE clk=${CLK_NS}ns)"
t0=$(date +%s)
yosys -m "$SLANG" -q -l "$OUT/${M}_yosys.log" "$WORK/$M.ys" > "$OUT/${M}_yosys.out" 2>&1
rc_ys=$?
t1=$(date +%s)
t_yosys=$((t1 - t0))

if [ $rc_ys -ne 0 ]; then
  echo "ERROR: yosys failed (rc=$rc_ys) for $M"
  grep -iE "ERROR" "$OUT/${M}_yosys.log" "$OUT/${M}_yosys.out" | head -n 15
  exit $rc_ys
fi

mem_v2_cnt=$(awk '/\$mem_v2/{cnt=$1} END{print cnt+0}' "$OUT/$M.stat")
fb_bb_cnt=$(grep -ch "g_fallback_bb" "$OUT/${M}_yosys.log" "$OUT/$M.stat" 2>/dev/null | awk '{s+=$1} END{print s+0}')
unmapped_cnt=$(grep -cE ' +\$_[A-Za-z0-9_]+$' "$OUT/$M.stat" 2>/dev/null || true)
if [ "$mem_v2_cnt" -ne 0 ] || [ "$fb_bb_cnt" -ne 0 ] || [ "${unmapped_cnt:-0}" -ne 0 ]; then
  echo "ERROR: unmapped mem_v2=$mem_v2_cnt fb_bb=$fb_bb_cnt unmapped_std=${unmapped_cnt:-0} in $M"
  grep -E ' +\$' "$OUT/$M.stat" | head -n 20
  exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
python3 "$SCRIPT_DIR/buf_high_fanout.py" "$WORK/$M.mapped.v" "$WORK/$M.buf.v" "${TIER1_MAX_FANOUT:-16}" > "$OUT/${M}_buf.log" 2>&1 || exit $?
cat "$OUT/${M}_buf.log"

# PrimeTime STA
cat > "$WORK/pt.tcl" <<TCL
set search_path [list \
  /eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140_180a \
  /eda-tools/pdk/TSMC28/digital/Front_End/timing_power_noise/NLDM/tcbn28hpcplusbwp12t40p140lvt_180a \
  $SRAM_DB_DIR]
set link_path [list * $STD_DB_SVT $STD_DB_LVT $SRAM_DBS]
read_verilog $WORK/$M.buf.v
current_design $M
set link_ok [link_design]
puts "PT_LINK_STATUS=\$link_ok"

set clk_port [get_ports -quiet clk]
if {[sizeof_collection \$clk_port] > 0} {
  create_clock -name clk -period $CLK_NS \$clk_port
  set_clock_uncertainty $UNC_NS [get_clocks clk]
  set_input_delay $IO_NS -clock clk [remove_from_collection [all_inputs] \$clk_port]
  set_output_delay $IO_NS -clock clk [all_outputs]
}
set rst_port [get_ports -quiet rst_n]
if {[sizeof_collection \$rst_port] > 0} {
  set_false_path -from \$rst_port
}

update_timing
report_qor > $OUT/pt_qor.rpt
report_global_timing > $OUT/pt_global_timing.rpt
report_timing -delay_type max -max_paths 10 -input_pins -nets -transition_time -capacitance -nosplit > $OUT/pt_timing_max.rpt
report_timing -delay_type max -from [all_registers -clock_pins] -to [all_registers -data_pins] -max_paths 10 -input_pins -nosplit > $OUT/pt_timing_reg2reg.rpt

set cells [get_cells -hier -filter "is_hierarchical==false"]
set total_a 0.0
set macro_a 0.0
set seq_a 0.0
set comb_a 0.0
set macro_c 0
set seq_c 0
set leaf_c [sizeof_collection \$cells]
foreach_in_collection c \$cells {
  set a [get_attribute -quiet \$c area]
  if {\$a eq ""} { set a 0.0 }
  set total_a [expr {\$total_a + \$a}]
  set is_bb [get_attribute -quiet \$c is_black_box]
  set is_seq [get_attribute -quiet \$c is_sequential]
  set ref [get_attribute -quiet \$c ref_name]
  if {\$is_bb eq "true" || [string match "TEM5N*" \$ref]} {
    set macro_a [expr {\$macro_a + \$a}]
    incr macro_c
  } elseif {\$is_seq eq "true"} {
    set seq_a [expr {\$seq_a + \$a}]
    incr seq_c
  } else {
    set comb_a [expr {\$comb_a + \$a}]
  }
}
set fp [open "$OUT/pt_area.rpt" w]
puts \$fp [format "Leaf Cell Count:      %d" \$leaf_c]
puts \$fp [format "Sequential Cells:     %d" \$seq_c]
puts \$fp [format "Macros/Black Boxes:   %d" \$macro_c]
puts \$fp [format "Combinational Area:   %.4f" \$comb_a]
puts \$fp [format "Sequential Area:      %.4f" \$seq_a]
puts \$fp [format "Macro Area:           %.4f" \$macro_a]
puts \$fp [format "Logic+FF Area:        %.4f" [expr {\$comb_a + \$seq_a}]]
puts \$fp [format "Total Area:           %.4f" \$total_a]
close \$fp
quit
TCL

t2=$(date +%s)
pt_shell -f "$WORK/pt.tcl" > "$OUT/${M}_pt.log" 2>&1
rc_pt=$?
t3=$(date +%s)
t_pt=$((t3 - t2))
t_total=$((t3 - t0))

if [ $rc_pt -ne 0 ]; then
  echo "ERROR: pt_shell failed (rc=$rc_pt) for $M"
  tail -n 25 "$OUT/${M}_pt.log"
  exit $rc_pt
fi

pt_link=$(grep -m1 "^PT_LINK_STATUS=" "$OUT/${M}_pt.log" | awk -F= '{print $2}' | tr -d ' ')
if [ "${pt_link:-0}" != "1" ]; then
  echo "ERROR: PT link_design failed (PT_LINK_STATUS=${pt_link:-missing}) for $M"
  grep -iE "Error:|unresolved" "$OUT/${M}_pt.log" | head -n 20
  exit 3
fi

echo "TIER1_DONE mod=$M mode=$SRAM_MODE clk=$CLK_NS t_yosys=${t_yosys}s t_pt=${t_pt}s t_total=${t_total}s" > "$OUT/timing_summary.txt"
cat "$OUT/pt_area.rpt" >> "$OUT/timing_summary.txt"
grep -E "PT_LINK_STATUS|Elapsed time|Maximum memory" "$OUT/${M}_pt.log" >> "$OUT/timing_summary.txt" || true
cat "$OUT/timing_summary.txt"
