// Ref: MemSubSystem/include/MemPtwBlock.h  select_walk_owner, apply_grant, apply_events, apply_wakeups
`default_nettype none

// The shared walker FSM:  IDLE -> L1_REQ -> L1_WAIT -> (L2_REQ -> L2_WAIT) -> IDLE.
// One cycle = select (IDLE only: round robin between the clients, a request latched THIS cycle can win) -> read request
// (issue / addr, combinational from the post-select state) -> grant from the route block (REQ -> WAIT, id kept)
// -> PTE event (id must match the granted request, otherwise it is a stale answer of a flushed walk and is ignored)
// -> wakeup (the read has to be re-issued: WAIT -> REQ) -> flush of the owner client (-> IDLE).
module ptw_walk_engine import memcpu_pkg::*; import ttg_cfg_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic cpu_en,
  // clients
  input  logic [PT_NCLIENT-1:0]   client_pending_a,
  input  logic [PT_VPN_W-1:0]     client_vpn_a      [PT_NCLIENT],
  input  logic [PT_PPN_W-1:0]     client_root_ppn_a [PT_NCLIENT],
  input  logic [PT_NCLIENT-1:0]   client_flush,
  input  logic                    sfence_flush,
  output logic [PT_NCLIENT-1:0]   client_sel,
  output logic [PT_NCLIENT-1:0]   client_publish,
  output logic                    pub_fault,
  output logic [PT_PPN_W-1:0]     pub_ppn,
  output logic [PT_PERM_W-1:0]    pub_perm,
  output logic [PT_LVL_W-1:0]     pub_level,
  // route block feedback
  input  logic                    grant_valid,
  input  logic [PT_ID_W-1:0]      grant_req_id,
  input  logic                    event_valid,
  input  logic [XLEN_BITS-1:0]    event_data,
  input  logic [PT_ID_W-1:0]      event_req_id,
  input  logic                    wakeup_walk,
  // read request towards the route block
  output logic                    issue_walk_read,
  output logic [31:0]             walk_read_addr
);

  ptw_state_e              state_q;
  logic                    owner_q;     // client of the active walk (meaningful unless IDLE)
  logic                    rr_q;        // client preferred by the next selection
  logic [PT_PPN_W-1:0]     l1_ppn_q;    // level-1 PTE ppn: base of the level-0 table
  logic [PT_ID_W-1:0]      req_id_q;    // id of the granted read (meaningful in *_WAIT)
  logic [PT_LVL_W-1:0]     level_q;     // level of the PTE read in flight (Sv39: 2, 1, 0)

  // ---- select (IDLE only; round robin, rr_q first) ----
  wire idle = state_q == PW_IDLE;
  logic pick_first, pick_second;
  wire  first  = rr_q;
  wire  second = !rr_q;
  assign pick_first  = idle && client_pending_a[first];
  assign pick_second = idle && !client_pending_a[first] && client_pending_a[second];
  wire  select_any   = pick_first || pick_second;
  wire  sel_client   = pick_first ? first : second;
  always_comb begin
    client_sel = '0;
    if (select_any) client_sel[sel_client] = 1'b1;
  end

  // state after select
  ptw_state_e state_b;
  logic       owner_b;
  always_comb begin
    state_b = select_any ? PW_STLB_LK : state_q;
    owner_b = select_any ? sel_client : owner_q;
  end

  // ---- read request (only in PW_L1_REQ / PW_L2_REQ; never in PW_IDLE/select_any) ----
  wire [PT_VPN_W-1:0] cur_vpn  = client_vpn_a[owner_q];
  wire [PT_PPN_W-1:0] cur_root = client_root_ppn_a[owner_q];
  always_comb begin
    issue_walk_read = 1'b0;
    walk_read_addr  = 32'd0;
    // PTE address = table base + VPN[level] * PTE size
    if (state_q == PW_L1_REQ) begin
      issue_walk_read = 1'b1;
      walk_read_addr  = {cur_root, cur_vpn[PT_VPN_PART_W * (PT_LEVELS - 1) +: PT_VPN_PART_W], PT_PTE_SHIFT'(0)};
    end else if (state_q == PW_L2_REQ) begin
      issue_walk_read = 1'b1;
      walk_read_addr  = {l1_ppn_q, cur_vpn[PT_VPN_PART_W * int'(level_q) +: PT_VPN_PART_W], PT_PTE_SHIFT'(0)};
    end
  end

  // ---- grant (state_q is already PW_L1_REQ or PW_L2_REQ; independent of select_any) ----
  ptw_state_e state_c;
  logic [PT_ID_W-1:0] req_id_c;
  always_comb begin
    state_c  = state_b;
    req_id_c = req_id_q;
    if (grant_valid) begin
      req_id_c = grant_req_id;
      if (state_q == PW_L1_REQ)      state_c = PW_L1_WAIT;
      else if (state_q == PW_L2_REQ) state_c = PW_L2_WAIT;
    end
  end

  // ---- PTE event (independent of select_any) ----
  wire in_l1_wait = (state_q == PW_L1_WAIT) || (grant_valid && (state_q == PW_L1_REQ));
  wire in_l2_wait = (state_q == PW_L2_WAIT) || (grant_valid && (state_q == PW_L2_REQ));
  wire in_wait    = in_l1_wait || in_l2_wait;
  wire event_hit  = event_valid && in_wait && (event_req_id == req_id_c);
  logic pte_fault, pte_pointer, pte_leaf;
  logic [PT_LVL_W-1:0]  pte_level;
  logic [PT_PPN_W-1:0]  pte_ppn;
  logic [PT_PERM_W-1:0] pte_perm;
  // the first read of a walk is at the top level, the following ones at level_q (one below the previous)
  assign pte_level = in_l1_wait ? PT_LVL_W'(PT_LEVELS - 1) : level_q;
  ptw_walk_pte u_pte (
    .pte(event_data), .level(pte_level),
    .fault(pte_fault), .pointer(pte_pointer), .leaf(pte_leaf), .ppn(pte_ppn), .perm(pte_perm)
  );

  // ---- L2 TLB + Superpage CAM + Sv39 PWC ----
  wire in_stlb_lk = (state_q == PW_STLB_LK);
  wire [PT_STLB_IDX_W-1:0] lk_rd_idx =
      client_vpn_a[sel_client][PT_STLB_IDX_W-1:0] ^ client_vpn_a[sel_client][PT_VPN_PART_W +: PT_STLB_IDX_W];
  logic                 l2_hit_leaf, l2_hit_pwc;
  logic [PT_PPN_W-1:0]  l2_hit_ppn, l2_pwc_ppn;
  logic [PT_PERM_W-1:0] l2_hit_perm;
  logic [PT_LVL_W-1:0]  l2_hit_level, l2_pwc_next_level;
  ptw_walk_l2tlb u_l2tlb (
    .clk, .rst_n, .cpu_en, .sfence_flush,
    .lk_rd_en       (select_any),
    .lk_rd_idx      (lk_rd_idx),
    .lk_en          (in_stlb_lk),
    .lk_vpn         (cur_vpn),
    .lk_root        (cur_root),
    .hit_leaf       (l2_hit_leaf),
    .hit_ppn        (l2_hit_ppn),
    .hit_perm       (l2_hit_perm),
    .hit_level      (l2_hit_level),
    .hit_pwc        (l2_hit_pwc),
    .pwc_ppn        (l2_pwc_ppn),
    .pwc_next_level (l2_pwc_next_level),
    .wr_leaf        (event_hit && pte_leaf),
    .wr_pwc         (event_hit && pte_pointer),
    .wr_vpn         (cur_vpn),
    .wr_root        (cur_root),
    .wr_ppn         (pte_ppn),
    .wr_perm        (pte_perm),
    .wr_level       (pte_level)
  );

  wire stlb_publish = in_stlb_lk && l2_hit_leaf;
  wire stlb_pwc_go  = in_stlb_lk && l2_hit_pwc;
  wire stlb_miss    = in_stlb_lk && !l2_hit_leaf && !l2_hit_pwc;
  wire publish_any  = stlb_publish || (event_hit && (pte_fault || pte_leaf));
  wire go_level0    = event_hit && pte_pointer;

  assign pub_fault  = stlb_publish ? 1'b0         : pte_fault;
  assign pub_ppn    = stlb_publish ? l2_hit_ppn   : pte_ppn;
  assign pub_perm   = stlb_publish ? l2_hit_perm  : pte_perm;
  assign pub_level  = stlb_publish ? l2_hit_level : pte_level;

  always_comb begin
    client_publish = '0;
    if (publish_any) client_publish[owner_q] = 1'b1;
  end

  ptw_state_e state_e;
  always_comb begin
    state_e = state_c;
    if (publish_any)                   state_e = PW_IDLE;
    else if (stlb_pwc_go || go_level0) state_e = PW_L2_REQ;
    else if (stlb_miss)                state_e = PW_L1_REQ;
  end

  // ---- wakeup: re-issue the read of an active walk ----
  ptw_state_e state_w;
  always_comb begin
    state_w = state_e;
    if (wakeup_walk) begin
      if (state_e == PW_L1_WAIT)      state_w = PW_L1_REQ;
      else if (state_e == PW_L2_WAIT) state_w = PW_L2_REQ;
    end
  end

  // ---- flush of the owner client abandons the walk ----
  wire flush_owner = (state_w != PW_IDLE) && client_flush[owner_b];
  ptw_state_e state_d;
  always_comb state_d = flush_owner ? PW_IDLE : state_w;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state_q  <= PW_IDLE;
      owner_q  <= 1'b0;
      rr_q     <= 1'b0;
      l1_ppn_q <= '0;
      req_id_q <= '0;
      level_q  <= '0;
    end else if (cpu_en) begin
      state_q  <= state_d;
      owner_q  <= owner_b;
      req_id_q <= req_id_c;
      if (select_any) rr_q <= !sel_client;
      if (stlb_pwc_go) begin
        l1_ppn_q <= l2_pwc_ppn;
        level_q  <= l2_pwc_next_level;
      end else if (stlb_miss) begin
        level_q  <= PT_LVL_W'(PT_LEVELS - 1);
      end else if (go_level0) begin
        l1_ppn_q <= pte_ppn;
        level_q  <= pte_level - PT_LVL_W'(1);
      end
    end
  end

endmodule

`default_nettype wire
