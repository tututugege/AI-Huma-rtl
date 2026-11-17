// Equivalence test: parallel tlb_mmu_core (rtl/) against the old serial-chain core (tlb_mmu_core_ref), same random
// inputs every cycle, every output compared. Inputs are arbitrary (not only what a real LSU/PTW would send), biased to a
// small page pool so that hits, shared walks, retire-then-start and refill forwarding happen often.
// Also checks ttg_first_set against req & -req for several widths.
`default_nettype none
module tlb_par_tb import ttg_cfg_pkg::*; import tlb_mmu_pkg::*; ;
  localparam int LANES = LSU_LDU_COUNT + LSU_STA_COUNT;
  localparam int ENTRIES = 8;   // small array: replacement and overlapping entries happen
  int unsigned CYCLES;

  logic clk = 0, rst_n = 0;
  logic fence, cancel, mxr, sum, mprv, ptw_req_ready, ptw_resp_valid;
  logic [1:0] privilege, mpp;
  logic [XLEN_BITS-1:0] satp;
  logic req_valid [LANES];
  logic [XLEN_BITS-1:0] req_vaddr [LANES];
  tlb_mmu_ptw_resp_t ptw_resp;

  // outputs, two copies
  logic rv_n [LANES], rv_r [LANES];
  logic [1:0] rr_n [LANES], rr_r [LANES];
  logic [31:0] rp_n [LANES], rp_r [LANES];
  logic qv_n, qv_r, rc_n, rc_r, fl_n, fl_r;
  logic [VPN_W-1:0] qvpn_n, qvpn_r;
  logic [21:0] qroot_n, qroot_r;

  tlb_mmu_core #(.LANES(LANES), .LD_LANES(LSU_LDU_COUNT), .FETCH(1'b0), .ENTRIES(ENTRIES)) u_new (
    .clk, .rst_n, .fence, .cancel, .satp, .privilege, .mxr, .sum, .mprv, .mpp, .req_valid, .req_vaddr,
    .ptw_req_ready, .ptw_resp_valid, .ptw_resp, .resp_valid(rv_n), .resp_result(rr_n), .resp_paddr(rp_n),
    .ptw_req_valid(qv_n), .ptw_req_vpn(qvpn_n), .ptw_req_root_ppn(qroot_n), .ptw_resp_consumed(rc_n), .ptw_flush(fl_n));
  tlb_mmu_core_ref #(.LANES(LANES), .LD_LANES(LSU_LDU_COUNT), .FETCH(1'b0), .ENTRIES(ENTRIES)) u_ref (
    .clk, .rst_n, .fence, .cancel, .satp, .privilege, .mxr, .sum, .mprv, .mpp, .req_valid, .req_vaddr,
    .ptw_req_ready, .ptw_resp_valid, .ptw_resp, .resp_valid(rv_r), .resp_result(rr_r), .resp_paddr(rp_r),
    .ptw_req_valid(qv_r), .ptw_req_vpn(qvpn_r), .ptw_req_root_ppn(qroot_r), .ptw_resp_consumed(rc_r), .ptw_flush(fl_r));

  // fetch flavour (ITLB): one lane, FETCH=1
  logic fv_n [1], fv_r [1];
  logic [1:0] fr_n [1], fr_r [1];
  logic [31:0] fp_n [1], fp_r [1];
  logic fqv_n, fqv_r, frc_n, frc_r, ffl_n, ffl_r;
  logic [VPN_W-1:0] fqvpn_n, fqvpn_r;
  logic [21:0] fqroot_n, fqroot_r;
  logic f_valid [1];
  logic [XLEN_BITS-1:0] f_vaddr [1];
  assign f_valid[0] = req_valid[0];
  assign f_vaddr[0] = req_vaddr[0];
  tlb_mmu_core #(.LANES(1), .FETCH(1'b1), .ENTRIES(ENTRIES)) u_fnew (
    .clk, .rst_n, .fence, .cancel, .satp, .privilege, .mxr, .sum, .mprv, .mpp, .req_valid(f_valid),
    .req_vaddr(f_vaddr), .ptw_req_ready, .ptw_resp_valid, .ptw_resp, .resp_valid(fv_n), .resp_result(fr_n),
    .resp_paddr(fp_n), .ptw_req_valid(fqv_n), .ptw_req_vpn(fqvpn_n), .ptw_req_root_ppn(fqroot_n),
    .ptw_resp_consumed(frc_n), .ptw_flush(ffl_n));
  tlb_mmu_core_ref #(.LANES(1), .FETCH(1'b1), .ENTRIES(ENTRIES)) u_fref (
    .clk, .rst_n, .fence, .cancel, .satp, .privilege, .mxr, .sum, .mprv, .mpp, .req_valid(f_valid),
    .req_vaddr(f_vaddr), .ptw_req_ready, .ptw_resp_valid, .ptw_resp, .resp_valid(fv_r), .resp_result(fr_r),
    .resp_paddr(fp_r), .ptw_req_valid(fqv_r), .ptw_req_vpn(fqvpn_r), .ptw_req_root_ppn(fqroot_r),
    .ptw_resp_consumed(frc_r), .ptw_flush(ffl_r));

  // ---- ttg_first_set against req & -req ----
  logic [63:0] fs_req;
  logic [0:0]  fs1_oh;  logic fs1_any;
  logic [2:0]  fs3_oh;  logic fs3_any;
  logic [6:0]  fs7_oh;  logic fs7_any;
  logic [7:0]  fs8_oh;  logic fs8_any;
  logic [12:0] fs13_oh; logic fs13_any;
  logic [63:0] fs64_oh; logic fs64_any;
  ttg_first_set #(.N(1))  u_fs1  (.req(fs_req[0:0]),  .onehot(fs1_oh),  .any(fs1_any));
  ttg_first_set #(.N(3))  u_fs3  (.req(fs_req[2:0]),  .onehot(fs3_oh),  .any(fs3_any));
  ttg_first_set #(.N(7))  u_fs7  (.req(fs_req[6:0]),  .onehot(fs7_oh),  .any(fs7_any));
  ttg_first_set #(.N(8))  u_fs8  (.req(fs_req[7:0]),  .onehot(fs8_oh),  .any(fs8_any));
  ttg_first_set #(.N(13)) u_fs13 (.req(fs_req[12:0]), .onehot(fs13_oh), .any(fs13_any));
  ttg_first_set #(.N(64)) u_fs64 (.req(fs_req),       .onehot(fs64_oh), .any(fs64_any));

  // ---- random stimulus ----
  logic [VPN_W-1:0] pool [6];
  logic [XLEN_BITS-1:0] satps [3];

  function automatic logic [XLEN_BITS-1:0] mk_satp(input int asid, input int root, input bit on);
    logic [63:0] s;
    s = '0;
    if (RV64) begin s[63:60] = on ? 4'd8 : 4'd0; s[44 +: 16] = 16'(asid); end
    else      begin s[31] = on; s[22 +: 9] = 9'(asid); end
    s[21:0] = 22'(root);
    return XLEN_BITS'(s);
  endfunction

  function automatic logic [XLEN_BITS-1:0] mk_vaddr(input logic [VPN_W-1:0] vpn);
    logic [63:0] v;
    v = 64'($urandom) & 64'hfff;
    v[12 +: VPN_W] = vpn;
    if (RV64) begin
      if ($urandom_range(0, 99) < 3) v[63:39] = 25'($urandom);        // mostly not canonical
      else if (v[38]) v[63:39] = '1;
    end
    return XLEN_BITS'(v);
  endfunction

  function automatic logic [VPN_W-1:0] pick_vpn();
    // superpage neighbours: same upper fields, different low field
    logic [VPN_W-1:0] v;
    v = pool[$urandom_range(0, 5)];
    if ($urandom_range(0, 9) == 0) v[VPN_PART_W-1:0] = VPN_PART_W'($urandom);
    return v;
  endfunction

  int unsigned mism = 0, cyc = 0;
  int unsigned c_hit = 0, c_issue = 0, c_retire = 0, c_retire_start = 0, c_fwd = 0, c_fault = 0, c_multi_walk = 0;
  int unsigned c_early = 0, c_consume_other = 0, c_fs = 0;

  task automatic drive();
    int bias;
    fence = $urandom_range(0, 199) == 0;
    cancel = $urandom_range(0, 24) == 0;
    satp = satps[$urandom_range(0, 9) < 8 ? 0 : $urandom_range(1, 2)];
    privilege = $urandom_range(0, 9) < 7 ? 2'd1 : 2'($urandom_range(0, 3));
    mpp = 2'($urandom); mprv = $urandom_range(0, 9) == 0;
    mxr = $urandom_range(0, 3) == 0; sum = $urandom_range(0, 1);
    bias = $urandom_range(0, 3);   // 0: sparse, 3: all lanes busy
    for (int l = 0; l < LANES; l++) begin
      req_valid[l] = $urandom_range(0, 3) < bias + 1;
      req_vaddr[l] = mk_vaddr(pick_vpn());
    end
    ptw_req_ready = $urandom_range(0, 3) != 0;
    ptw_resp_valid = $urandom_range(0, 2) == 0;
    ptw_resp.fault = $urandom_range(0, 9) == 0;
    // response mostly for the page the walk is on (as a real PTW would), sometimes for another page
    ptw_resp.vpn = $urandom_range(0, 4) != 0 ? u_ref.walk_q.vpn : pick_vpn();
    ptw_resp.level = LVL_W'($urandom_range(0, LEVELS - 1));
    if ($urandom_range(0, 2) != 0) ptw_resp.level = '0;
    ptw_resp.ppn = PPN_W'($urandom);
    ptw_resp.perm = 8'($urandom) | ($urandom_range(0, 3) != 0 ? 8'hcf : 8'h00);   // mostly D A . . X W R V
    fs_req = {$urandom, $urandom};
    if ($urandom_range(0, 1) == 0) fs_req = fs_req & {$urandom, $urandom} & {$urandom, $urandom};
  endtask

  function automatic bit cmp_fs();
    logic [63:0] r;
    r = fs_req;
    return fs1_oh == (r[0:0] & (~r[0:0] + 1'b1)) && fs1_any == |r[0:0]
        && fs3_oh == (r[2:0] & (~r[2:0] + 3'd1)) && fs3_any == |r[2:0]
        && fs7_oh == (r[6:0] & (~r[6:0] + 7'd1)) && fs7_any == |r[6:0]
        && fs8_oh == (r[7:0] & (~r[7:0] + 8'd1)) && fs8_any == |r[7:0]
        && fs13_oh == (r[12:0] & (~r[12:0] + 13'd1)) && fs13_any == |r[12:0]
        && fs64_oh == (r & (~r + 64'd1)) && fs64_any == |r;
  endfunction

  initial begin
    if (!$value$plusargs("cycles=%d", CYCLES)) CYCLES = 1000000;
    for (int i = 0; i < 6; i++) pool[i] = VPN_W'($urandom);
    pool[1][VPN_W-1:VPN_PART_W] = pool[0][VPN_W-1:VPN_PART_W];   // two pages in one megapage
    satps[0] = mk_satp(5, 1, 1); satps[1] = mk_satp(6, 2, 1); satps[2] = mk_satp(5, 3, 1);
    drive();
    #1 clk = 1; #1 clk = 0; #1 clk = 1; #1 clk = 0;
    rst_n = 1;
    for (cyc = 0; cyc < CYCLES; cyc++) begin
      drive();
      #1;
      for (int l = 0; l < LANES; l++)
        if (rv_n[l] !== rv_r[l] || rr_n[l] !== rr_r[l] || rp_n[l] !== rp_r[l]) begin
          if (mism < 10) $display("MISMATCH cyc %0d lane %0d: new %0d/%0d/%h ref %0d/%0d/%h", cyc, l, rv_n[l], rr_n[l],
                                  rp_n[l], rv_r[l], rr_r[l], rp_r[l]);
          mism++;
        end
      if (qv_n !== qv_r || qvpn_n !== qvpn_r || qroot_n !== qroot_r || rc_n !== rc_r || fl_n !== fl_r) begin
        if (mism < 10) $display("MISMATCH cyc %0d ptw: new %0d %h %h %0d %0d ref %0d %h %h %0d %0d", cyc, qv_n, qvpn_n,
                                qroot_n, rc_n, fl_n, qv_r, qvpn_r, qroot_r, rc_r, fl_r);
        mism++;
      end
      if (fv_n[0] !== fv_r[0] || fr_n[0] !== fr_r[0] || fp_n[0] !== fp_r[0] || fqv_n !== fqv_r || fqvpn_n !== fqvpn_r
          || fqroot_n !== fqroot_r || frc_n !== frc_r || ffl_n !== ffl_r) begin
        if (mism < 10) $display("MISMATCH cyc %0d fetch lane", cyc);
        mism++;
      end
      if (!cmp_fs()) begin
        if (mism < 10) $display("MISMATCH cyc %0d first_set req %h", cyc, fs_req);
        mism++;
      end
      // coverage
      for (int l = 0; l < LANES; l++) if (rv_r[l] && rr_r[l] == RES_HIT && rp_r[l] != req_vaddr[l][31:0]) c_hit++;
      if (u_new.ptw_req_valid) c_issue++;
      if (u_new.a_retire) c_retire++;
      if (u_new.a_retire && u_new.b_any) c_retire_start++;
      if (|u_new.use_refill1 && |(u_new.use_refill1 & ~u_new.miss1 & u_new.miss0)) c_fwd++;
      if (u_new.a_retire && !u_new.a_ok) c_fault++;
      if ($countones(u_new.a_req) > 1) c_multi_walk++;
      if (u_new.early_consume && !fence && !cancel) c_early++;
      if (u_new.a_consume && !u_new.a_retire) c_consume_other++;
      clk = 1; #1 clk = 0;
    end
    $display("TLBPAR XLEN=%0d cycles=%0d mismatches=%0d", XLEN_BITS, CYCLES, mism);
    $display("  coverage: translated-hit-lanes=%0d ptw-req=%0d retire=%0d retire+new-walk=%0d refill-forward=%0d",
             c_hit, c_issue, c_retire, c_retire_start, c_fwd);
    $display("            retire-fault=%0d multi-lane-same-walk=%0d early-retire=%0d consume-other-page=%0d",
             c_fault, c_multi_walk, c_early, c_consume_other);
    if (mism == 0) $display("TLBPAR PASS"); else $display("TLBPAR FAIL");
    $finish;
  end
endmodule
`default_nettype wire
