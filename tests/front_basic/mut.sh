#!/usr/bin/env bash
# Mutation check for the front_basic modules.  Each mutant is ONE textual change applied to a copy of rtl/;
# the replay must FAIL.  Prints, per mutant, the first mismatch on the real-program set and on the generated set.
#   usage: bash tests/front_basic/mut.sh            (needs traces from record_all.sh + run_pure.sh + run_fifo.sh)
MAIN=$(cd "$(dirname "$0")/../.." && pwd); cd "$MAIN"
run() {   # <id> <module> <file> <old> <new> ; real traces: REAL (env per module) ; random: rand_*/exh_*
  local id=$1 mod=$2 file=$3 old=$4 new=$5
  if [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $id "* ]]; then return; fi
  local T; T=$(mktemp -d)
  cp -R rtl spec "$T/"
  python3 - "$T/$file" "$old" "$new" <<'PY' || { echo "$id: PATTERN NOT FOUND"; rm -rf "$T"; return; }
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) >= 1
open(p, "w").write(s.replace(old, new, 1))
PY
  local FILES=(); while IFS= read -r f; do FILES+=("$f"); done < <(bash scripts/rtl_files.sh "$T")
  ( cd "$T" && bash "$MAIN/scripts/hbuild.sh" "spec/$mod.io" "$T/build" "${FILES[@]}" ) >/dev/null 2>&1 || { echo "$id: BUILD FAILED"; rm -rf "$T"; return; }
  local real="" rnd=""
  local ALL=""; for t in traces/$mod/*.trc; do case $(basename $t) in rand_*|exh_*) ;; *) ALL="$ALL $(basename $t .trc)";; esac; done
  for t in ${REAL_SET:-dhrystone coremark smc-div vm_pagefault_test} $ALL; do
    [ -f "traces/$mod/$t.trc" ] || continue
    r=$("$T/build/replay" "traces/$mod/$t.trc" --max-fail 1 | grep -m1 MISMATCH | sed 's/  MISMATCH //' | cut -c1-70)
    [ -n "$r" ] && { real="$t: $r"; break; }
  done
  for t in traces/$mod/rand_*.trc traces/$mod/exh_*.trc; do
    [ -f "$t" ] || continue
    r=$("$T/build/replay" "$t" --max-fail 1 | grep -m1 MISMATCH | sed 's/  MISMATCH //' | cut -c1-70)
    [ -n "$r" ] && { rnd="$(basename $t .trc): $r"; break; }
  done
  echo "$id | $mod | real: ${real:-NOT CAUGHT} | random: ${rnd:-NOT CAUGHT}"
  rm -rf "$T"
}
F=rtl/frontend
# ---- predecode ----
run P1 predecode $F/predecode_lane.sv "inst[31], inst[7], inst[30:25]" "inst[31], inst[7] ^ inst[31], inst[30:25]"
run P2 predecode $F/predecode_lane.sv "(is_jal || is_branch) ? (pc + imm_sel) : 32'd0" "(is_jal || is_branch || is_jalr) ? (pc + imm_sel) : 32'd0"
run P3 predecode $F/predecode_lane.sv "assign is_jal    = inst_valid && (opcode == OPCODE_JAL);" "assign is_jal    = (opcode == OPCODE_JAL);"
run P4 predecode $F/predecode.sv "fetch_pc + 32'(i * INST_BYTES)" "fetch_pc + 32'(i * 2)"
run P5 predecode $F/predecode_lane.sv "{{11{inst[31]}}, inst[31], inst[19:12]" "{{11{1'b0}}, inst[31], inst[19:12]"
# ---- sequential_next_pc ----
run S1 sequential_next_pc $F/sequential_next_pc.sv "!= (fetch_pc & LINE_MASK)) ? (group_end_pc & LINE_MASK) : group_end_pc" "!= (fetch_pc & LINE_MASK)) ? group_end_pc : group_end_pc"
run S2 sequential_next_pc $F/sequential_next_pc.sv "lane_invalid[i] = !inst_valid[i];" "lane_invalid[i] = !inst_valid[i] || (i == FETCH_WIDTH - 1);"
run S3 sequential_next_pc $F/sequential_next_pc.sv "PREFIX_W'(FETCH_WIDTH)" "PREFIX_W'(FETCH_WIDTH - 1)"
run S4 sequential_next_pc $F/sequential_next_pc.sv "(fetch_pc & LINE_MASK)) ?" "(group_end_pc & 32'hffffff00)) ?"
# ---- predecode_checker ----
run C1 predecode_checker $F/predecode_checker.sv "lane_uses_target[i] = (predecode_type[i] == PREDECODE_DIRECT_JUMP_NO_JAL) || (predecode_type[i] == PREDECODE_JAL);" "lane_uses_target[i] = (predecode_type[i] != PREDECODE_NON_BRANCH);"
run C2 predecode_checker $F/predecode_checker.sv "PREDECODE_DIRECT_JUMP_NO_JAL: taken[i] = predict_dir[i];" "PREDECODE_DIRECT_JUMP_NO_JAL: taken[i] = !predict_dir[i];"
run C3 predecode_checker $F/predecode_checker.sv "if (!any_taken)                   predict_next_fetch_address_corrected = seq_next_pc;" "if (!any_taken)                   predict_next_fetch_address_corrected = seq_next_pc ^ 32'd4;"
run C4 predecode_checker $F/predecode_checker.sv "predecode_flush_enable = (predict_next_fetch_address != predict_next_fetch_address_corrected);" "predecode_flush_enable = (predict_next_fetch_address[31:2] != predict_next_fetch_address_corrected[31:2]);"
run C5 predecode_checker $F/predecode_checker.sv "PREDECODE_JALR:               taken[i] = 1'b1;" "PREDECODE_JALR:               taken[i] = predict_dir[i];"
# ---- FIFO (front_fifo shared by the four wrappers; evaluated through fetch_addr_fifo, full threshold also through ptab) ----
run F1 fetch_addr_fifo $F/front_fifo.sv "rd_ptr_d          = clear ? wr_ptr_q : rd_ptr_q + PTR_W'(rd_valid);" "rd_ptr_d          = clear ? rd_ptr_q : rd_ptr_q + PTR_W'(rd_valid);"
run F2 fetch_addr_fifo $F/front_fifo.sv "rd_valid          = rd_en && !clear && !empty;" "rd_valid          = rd_en && !empty;"
run F3 fetch_addr_fifo $F/front_fifo.sv "count_after_clear = clear ? '0 : count_q;" "count_after_clear = count_q;"
run F4 fetch_addr_fifo $F/front_fifo.sv "mem_d[s] = (wr_en && wr_ptr_q == PTR_W'(s)) ? wdata : mem_q[s];" "mem_d[s] = (wr_en && !clear && wr_ptr_q == PTR_W'(s)) ? wdata : mem_q[s];"
run F5 fetch_addr_fifo $F/front_fifo.sv "assign full  = (count_q >= CNT_W'(FULL_AT));" "assign full  = (count_q > CNT_W'(FULL_AT));"
run F6 ptab $F/front_fifo.sv "assign rdata = mem_q[rd_ptr_q];" "assign rdata = mem_q[rd_ptr_q + PTR_W'(rd_valid)];"
run F7 front2back_fifo $F/front_fifo.sv "wr_ptr_d          = wr_ptr_q + PTR_W'(wr_en);" "wr_ptr_d          = (wr_ptr_q + PTR_W'(wr_en)) & PTR_W'(DEPTH - 2);"
run F8 inst_fifo $F/inst_fifo.sv "wr_entry.predecode_target_address[i] = wr_predecode_target_address[i];" "wr_entry.predecode_target_address[i] = wr_predecode_target_address[FETCH_WIDTH - 1 - i];"
run F10 front2back_fifo $F/front2back_fifo.sv "rd_predict_base_pc                              = rd_entry.meta.predict_base_pc;" "rd_predict_base_pc                              = rd_entry.meta.predict_base_pc + 32'd4;"
# ---- front_ctrl ----
run K1 front_ctrl $F/front_refetch_ctrl.sv "refetch_address = be_refetch ? be_refetch_address : predecode_refetch_address_q;" "refetch_address = predecode_refetch_q ? predecode_refetch_address_q : be_refetch_address;"
run K2 front_ctrl $F/front_ctrl_enables.sv "f2b_use_bypass     = be_fifo_read_enable && f2b_empty && predecode_can_run;" "f2b_use_bypass     = be_fifo_read_enable && predecode_can_run;"
run K3 front_ctrl $F/front_ctrl_enables.sv "bpu_can_run           = !bpu_stall || global_refetch;" "bpu_can_run           = !bpu_stall;"
run K4 front_ctrl $F/front_ctrl_enables.sv "fa_wr_en              = bpu_icache_read_valid && bpu_can_run;" "fa_wr_en              = bpu_icache_read_valid;"
run K5 front_ctrl $F/front_ctrl_enables.sv "ptab_wr_en            = bpu_ptab_write_enable && !ptab_full && !global_refetch;" "ptab_wr_en            = bpu_ptab_write_enable && !global_refetch;"
run K6 front_ctrl $F/front_ctrl_enables.sv "do_predecode_flush = predecode_can_run && checker_flush_enable;" "do_predecode_flush = checker_flush_enable;"
run K7 front_ctrl $F/front_ctrl_enables.sv "predecode_can_run = !inst_empty && !ptab_empty && !f2b_full && !global_refetch;" "predecode_can_run = !inst_empty && !ptab_empty && !f2b_full && !be_refetch;"
run K8 front_ctrl $F/front_ctrl_enables.sv "f2b_head_valid     = be_fifo_read_enable && !be_refetch && !f2b_empty;" "f2b_head_valid     = be_fifo_read_enable && !(be_refetch && predecode_can_run) && !f2b_empty;"
run K9 front_ctrl $F/front_ctrl_enables.sv "bpu_icache_read_ready = !fa_full && bpu_can_run;" "bpu_icache_read_ready = bpu_can_run;"
run K10 front_ctrl $F/front_refetch_ctrl.sv "predecode_refetch_address_d = predecode_flush_address;" "predecode_refetch_address_d = predecode_flush_address ^ 32'd2;"
