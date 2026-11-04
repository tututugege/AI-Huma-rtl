// Coverage events of axi_llc_core, for scratch builds only (svlint S5 forbids $display in rtl/).
// Inserted before `endmodule` of axi_llc_core.sv by tests/axi_llc/cover_run.sh; every tick on which an event holds
// prints one line "COV <name>"; the runner counts the lines.
  always @(posedge clk) if (rst_n) begin
    if (|bp_grant && mwr_ready) $display("COV byp_write_issued");
    if (|bp_resp_w) $display("COV byp_write_response");
    if (u_resolve.hit_w_ok && lk_bypass) $display("COV byp_write_hit");
    if (u_resolve.miss_w_byp) $display("COV byp_write_miss");
    if (act && lk_is_write && lk_bypass && wp_ctx_strb[lk_master[0]] == 64'd0) $display("COV byp_lookup_after_ctx_cleared");
    if (u_resolve.hit_w_ok && !lk_bypass && !u_resolve.full_write) $display("COV partial_write_hit");
    if (u_resolve.miss_w_part) $display("COV partial_miss_alloc");
    if (u_resolve.miss_w_part && u_resolve.vdirty) $display("COV partial_miss_alloc_dirty_victim");
    if (act && !u_resolve.hit_any && lk_is_write && !lk_bypass && u_resolve.pick_ok && !u_resolve.full_write &&
        !u_resolve.mshr_ok) $display("COV partial_miss_retry_mshr");
    if (rf_wr_done) $display("COV partial_refill_done");
    if (rf_park && e_is_write) $display("COV partial_refill_park_victim");
    if (rf_wr_done && wp_cpend_q[e_master[0]] == 1'b0) $display("COV partial_refill_ctx_not_pending");
    if (v_own_resp) $display("COV owner_victim_answer");
    if (v_own_resp && |u_mshr.own_oh) $display("COV owner_victim_answer_entry_found");
    if (v_own_resp && !(|u_mshr.own_oh)) $display("COV owner_victim_answer_no_entry");
    if (v_bp_resp && !(|bp_owner)) $display("COV UNEXPECTED_orphan_mem_write_response");
  end
