// Central SVA bind declarations (compiled only when SOC_SVA=1; zero impact on synthesis or fast builds)
bind rob_core_cpt sva_rob u_sva_rob (
  .clk             (clk),
  .rst_n           (rst_n),
  .count_q         (count_q),
  .head_oh_q       (head_oh_q),
  .hb_oh_q         (hb_oh_q),
  .rob2dis_empty   (rob2dis_empty),
  .rob2dis_free    (rob2dis_free),
  .commit_valid    (commit_valid),
  .bcast_flush     (bcast_flush),
  .bcast_exception (bcast_exception),
  .bcast_interrupt (bcast_interrupt),
  .dec_mispred     (dec_mispred)
);

bind ren_core sva_ren u_sva_ren (
  .clk         (clk),
  .rst_n       (rst_n),
  .free_count  (free_count),
  .alloc_req   (alloc_req),
  .alloc_valid (alloc_valid),
  .fire        (fire),
  .elim        (elim),
  .walk_active (walk_active),
  .rob_flush   (rob_flush),
  .dec_mispred (dec_mispred)
);

bind lp_core sva_lsu u_sva_lsu (
  .clk                       (clk),
  .rst_n                     (rst_n),
  .count_q                   (count_q),
  .ccount_q                  (ccount_q),
  .o_stq_free                (o_stq_free),
  .o_ldq_free                (o_ldq_free),
  .o_committed_store_pending (o_committed_store_pending),
  .unc_valid_q               (unc_valid_q),
  .rsv_valid_q               (rsv_valid_q)
);

bind soc_top sva_axi_ddr u_sva_axi_ddr (
  .clk       (clk),
  .rst_n     (rst_n),
  .d_arvalid (d_arvalid),
  .d_arready (d_arready),
  .d_arid    (d_arid),
  .d_araddr  (d_araddr),
  .d_arlen   (d_arlen),
  .d_rvalid  (d_rvalid),
  .d_rready  (d_rready),
  .d_awvalid (d_awvalid),
  .d_awready (d_awready),
  .d_awid    (d_awid),
  .d_awaddr  (d_awaddr),
  .d_awlen   (d_awlen),
  .d_wvalid  (d_wvalid),
  .d_wready  (d_wready),
  .d_wdata   (d_wdata),
  .d_wstrb   (d_wstrb),
  .d_wlast   (d_wlast),
  .d_bvalid  (d_bvalid),
  .d_bready  (d_bready)
);
