// Ref: MemSubSystem/include/MemPtwBlock.h  apply_stlb_lookup, apply_l2tlb_seq
`default_nettype none

// Unified L2 TLB (4KB set-associative 1RW SRAM, 3-bit tree-PLRU) + Superpage CAM (RR) + Sv39 Page Walk Cache (RR).
// Cycle T (PW_IDLE, lk_rd_en=select_any): starts 1RW SRAM read for lk_rd_idx into stlb_rd_q.
// Cycle T+1 (PW_STLB_LK, lk_en=1): compares stlb_rd_q + stlb_valid_q, SP CAM, and PWC against (lk_vpn, lk_root).
// On memory walk completion (wr_leaf / wr_pwc, mutually exclusive with lk_rd_en & lk_en): refills STLB/SP/PWC.
// On sfence_flush: invalidates all valid bits and resets PLRU / RR state at posedge.
module ptw_walk_l2tlb import memcpu_pkg::*; import ttg_cfg_pkg::*;
  import ttg_util_pkg::ttg_plru4_touch, ttg_util_pkg::ttg_plru4_victim; (
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      cpu_en,
  input  logic                      sfence_flush,
  // Cycle T: 1RW SRAM read launch
  input  logic                      lk_rd_en,
  input  logic [PT_STLB_IDX_W-1:0]  lk_rd_idx,
  // Cycle T+1: tag compare & hit/PWC outputs
  input  logic                      lk_en,
  input  logic [PT_VPN_W-1:0]       lk_vpn,
  input  logic [PT_PPN_W-1:0]       lk_root,
  output logic                      hit_leaf,
  output logic [PT_PPN_W-1:0]       hit_ppn,
  output logic [PT_PERM_W-1:0]      hit_perm,
  output logic [PT_LVL_W-1:0]       hit_level,
  output logic                      hit_pwc,
  output logic [PT_PPN_W-1:0]       pwc_ppn,
  output logic [PT_LVL_W-1:0]       pwc_next_level,
  // Walk refill (mutually exclusive with lk_rd_en and lk_en)
  input  logic                      wr_leaf,
  input  logic                      wr_pwc,
  input  logic [PT_VPN_W-1:0]       wr_vpn,
  input  logic [PT_PPN_W-1:0]       wr_root,
  input  logic [PT_PPN_W-1:0]       wr_ppn,
  input  logic [PT_PERM_W-1:0]      wr_perm,
  input  logic [PT_LVL_W-1:0]       wr_level
);

  // ---- 4KB STLB 1RW SRAM payload layout: {global(1), root(20), vpn(27), ppn(20), perm(8)} = 76 bits ----
  localparam int STLB_ENTRY_W = 1 + PT_PPN_W + PT_VPN_W + PT_PPN_W + PT_PERM_W;
  localparam int B_PERM_LO = 0;
  localparam int B_PPN_LO  = PT_PERM_W;
  localparam int B_VPN_LO  = B_PPN_LO + PT_PPN_W;
  localparam int B_ROOT_LO = B_VPN_LO + PT_VPN_W;
  localparam int B_GLOB    = B_ROOT_LO + PT_PPN_W;

  // ---- STLB storage: 4 banks of 256 x 76b 1RW SRAM (declared per-way inside generate) + valid/PLRU FFs ----
  logic [STLB_ENTRY_W-1:0] stlb_rd_q   [PT_STLB_WAYS];
  logic [PT_STLB_WAYS-1:0] stlb_valid_q[PT_STLB_SETS];
  logic [2:0]              stlb_plru_q [PT_STLB_SETS];

  // ---- Superpage CAM (8 entries, RR replacement) ----
  logic                    sp_valid_q  [PT_SP_N];
  logic                    sp_global_q [PT_SP_N];
  logic [PT_LVL_W-1:0]     sp_lvl_q    [PT_SP_N];
  logic [PT_PPN_W-1:0]     sp_root_q   [PT_SP_N];
  logic [PT_VPN_PART_W-1:0] sp_vpn2_q  [PT_SP_N];
  logic [PT_VPN_PART_W-1:0] sp_vpn1_q  [PT_SP_N];
  logic [PT_PPN_W-1:0]     sp_ppn_q    [PT_SP_N];
  logic [PT_PERM_W-1:0]    sp_perm_q   [PT_SP_N];
  logic [PT_SP_IDX_W-1:0]  sp_rr_q;

  // ---- Sv39 PWC (16 entries, RR replacement) ----
  logic                    pwc_valid_q [PT_PWC_N];
  logic                    pwc_isl1_q  [PT_PWC_N];   // 0 = L2 (top), 1 = L1 (mid)
  logic [PT_PPN_W-1:0]     pwc_root_q  [PT_PWC_N];
  logic [PT_VPN_PART_W-1:0] pwc_vpn2_q [PT_PWC_N];
  logic [PT_VPN_PART_W-1:0] pwc_vpn1_q [PT_PWC_N];
  logic [PT_PPN_W-1:0]     pwc_ppn_q   [PT_PWC_N];
  logic [PT_PWC_IDX_W-1:0] pwc_rr_q;

  // ---- Lookup decode (Cycle T+1) ----
  wire [PT_STLB_IDX_W-1:0]  lk_idx  = lk_vpn[PT_STLB_IDX_W-1:0] ^ lk_vpn[PT_VPN_PART_W +: PT_STLB_IDX_W];
  wire [PT_VPN_PART_W-1:0]  lk_vpn2 = lk_vpn[2 * PT_VPN_PART_W +: PT_VPN_PART_W];
  wire [PT_VPN_PART_W-1:0]  lk_vpn1 = lk_vpn[1 * PT_VPN_PART_W +: PT_VPN_PART_W];

  // 1. 4KB STLB hit (lowest matching way)
  logic                     stlb_hit;
  logic [PT_STLB_WAY_W-1:0] stlb_hit_way;
  logic [PT_PPN_W-1:0]      stlb_hit_ppn;
  logic [PT_PERM_W-1:0]     stlb_hit_perm;
  always_comb begin
    stlb_hit      = 1'b0;
    stlb_hit_way  = '0;
    stlb_hit_ppn  = '0;
    stlb_hit_perm = '0;
    for (int w = PT_STLB_WAYS - 1; w >= 0; w--) begin
      logic                    e_glob;
      logic [PT_PPN_W-1:0]     e_root;
      logic [PT_VPN_W-1:0]     e_vpn;
      e_glob = stlb_rd_q[w][B_GLOB];
      e_root = stlb_rd_q[w][B_ROOT_LO +: PT_PPN_W];
      e_vpn  = stlb_rd_q[w][B_VPN_LO  +: PT_VPN_W];
      if (lk_en && stlb_valid_q[lk_idx][w] && (e_vpn == lk_vpn) && (e_glob || (e_root == lk_root))) begin
        stlb_hit      = 1'b1;
        stlb_hit_way  = PT_STLB_WAY_W'(w);
        stlb_hit_ppn  = stlb_rd_q[w][B_PPN_LO  +: PT_PPN_W];
        stlb_hit_perm = stlb_rd_q[w][B_PERM_LO +: PT_PERM_W];
      end
    end
  end

  // 2. Superpage CAM hit (lowest matching entry)
  logic                sp_hit;
  logic [PT_PPN_W-1:0] sp_hit_ppn;
  logic [PT_PERM_W-1:0] sp_hit_perm;
  logic [PT_LVL_W-1:0] sp_hit_lvl;
  always_comb begin
    sp_hit      = 1'b0;
    sp_hit_ppn  = '0;
    sp_hit_perm = '0;
    sp_hit_lvl  = '0;
    for (int i = PT_SP_N - 1; i >= 0; i--) begin
      if (lk_en && sp_valid_q[i] && (sp_global_q[i] || (sp_root_q[i] == lk_root)) &&
          (sp_vpn2_q[i] == lk_vpn2) && ((sp_lvl_q[i] == PT_LVL_W'(2)) || (sp_vpn1_q[i] == lk_vpn1))) begin
        sp_hit      = 1'b1;
        sp_hit_ppn  = sp_ppn_q[i];
        sp_hit_perm = sp_perm_q[i];
        sp_hit_lvl  = sp_lvl_q[i];
      end
    end
  end

  // 3. PWC hit: L1 (level 1 -> next level 0) has priority over L2 (level 2 -> next level 1)
  logic                pwc_l1_hit, pwc_l2_hit;
  logic [PT_PPN_W-1:0] pwc_l1_ppn, pwc_l2_ppn;
  always_comb begin
    pwc_l1_hit = 1'b0;
    pwc_l1_ppn = '0;
    pwc_l2_hit = 1'b0;
    pwc_l2_ppn = '0;
    for (int i = PT_PWC_N - 1; i >= 0; i--) begin
      if (lk_en && pwc_valid_q[i] && pwc_isl1_q[i] && (pwc_root_q[i] == lk_root) &&
          (pwc_vpn2_q[i] == lk_vpn2) && (pwc_vpn1_q[i] == lk_vpn1)) begin
        pwc_l1_hit = 1'b1;
        pwc_l1_ppn = pwc_ppn_q[i];
      end
      if (lk_en && pwc_valid_q[i] && !pwc_isl1_q[i] && (pwc_root_q[i] == lk_root) &&
          (pwc_vpn2_q[i] == lk_vpn2)) begin
        pwc_l2_hit = 1'b1;
        pwc_l2_ppn = pwc_ppn_q[i];
      end
    end
  end

  // Lookup outputs
  assign hit_leaf       = stlb_hit || sp_hit;
  assign hit_ppn        = stlb_hit ? stlb_hit_ppn  : sp_hit_ppn;
  assign hit_perm       = stlb_hit ? stlb_hit_perm : sp_hit_perm;
  assign hit_level      = stlb_hit ? PT_LVL_W'(0)  : sp_hit_lvl;
  assign hit_pwc        = !hit_leaf && (pwc_l1_hit || pwc_l2_hit);
  assign pwc_ppn        = pwc_l1_hit ? pwc_l1_ppn  : pwc_l2_ppn;
  assign pwc_next_level = pwc_l1_hit ? PT_LVL_W'(0) : PT_LVL_W'(1);

  // ---- Write slot selection ----
  wire wr_stlb = wr_leaf && (wr_level == PT_LVL_W'(0));
  wire wr_sp   = wr_leaf && (wr_level != PT_LVL_W'(0));
  wire wr_glob = wr_perm[5];   // PTE_G
  wire [PT_STLB_IDX_W-1:0]  wr_stlb_idx = wr_vpn[PT_STLB_IDX_W-1:0] ^ wr_vpn[PT_VPN_PART_W +: PT_STLB_IDX_W];
  wire [PT_VPN_PART_W-1:0]  wr_vpn2     = wr_vpn[2 * PT_VPN_PART_W +: PT_VPN_PART_W];
  wire [PT_VPN_PART_W-1:0]  wr_vpn1     = wr_vpn[1 * PT_VPN_PART_W +: PT_VPN_PART_W];
  wire [STLB_ENTRY_W-1:0]   wr_stlb_entry = {wr_glob, wr_root, wr_vpn, wr_ppn, wr_perm};

  // STLB victim way: first invalid way, else tree-PLRU victim (no match possible after STLB miss)
  logic                     stlb_has_inv;
  logic [PT_STLB_WAY_W-1:0] stlb_inv_way, wr_stlb_way;
  always_comb begin
    stlb_has_inv = 1'b0;
    stlb_inv_way = '0;
    for (int w = PT_STLB_WAYS - 1; w >= 0; w--) begin
      if (!stlb_valid_q[wr_stlb_idx][w]) begin
        stlb_has_inv = 1'b1;
        stlb_inv_way = PT_STLB_WAY_W'(w);
      end
    end
    wr_stlb_way = stlb_has_inv ? stlb_inv_way : ttg_plru4_victim(stlb_plru_q[wr_stlb_idx]);
  end

  // SP CAM write slot: matching entry, else first invalid, else sp_rr_q
  logic                   sp_has_match, sp_has_inv, sp_evict;
  logic [PT_SP_IDX_W-1:0] sp_match_slot, sp_inv_slot, wr_sp_slot;
  always_comb begin
    sp_has_match  = 1'b0;
    sp_match_slot = '0;
    sp_has_inv    = 1'b0;
    sp_inv_slot   = '0;
    for (int i = PT_SP_N - 1; i >= 0; i--) begin
      if (sp_valid_q[i] && (sp_lvl_q[i] == wr_level) && (sp_global_q[i] || (sp_root_q[i] == wr_root)) &&
          (sp_vpn2_q[i] == wr_vpn2) && ((wr_level == PT_LVL_W'(2)) || (sp_vpn1_q[i] == wr_vpn1))) begin
        sp_has_match  = 1'b1;
        sp_match_slot = PT_SP_IDX_W'(i);
      end
      if (!sp_valid_q[i]) begin
        sp_has_inv  = 1'b1;
        sp_inv_slot = PT_SP_IDX_W'(i);
      end
    end
    sp_evict   = !sp_has_match && !sp_has_inv;
    wr_sp_slot = sp_has_match ? sp_match_slot : (sp_has_inv ? sp_inv_slot : sp_rr_q);
  end

  // PWC write slot: matching entry, else first invalid, else pwc_rr_q
  wire                     wr_pwc_isl1 = (wr_level == PT_LVL_W'(1));
  logic                    pwc_has_match, pwc_has_inv, pwc_evict;
  logic [PT_PWC_IDX_W-1:0] pwc_match_slot, pwc_inv_slot, wr_pwc_slot;
  always_comb begin
    pwc_has_match  = 1'b0;
    pwc_match_slot = '0;
    pwc_has_inv    = 1'b0;
    pwc_inv_slot   = '0;
    for (int i = PT_PWC_N - 1; i >= 0; i--) begin
      if (pwc_valid_q[i] && (pwc_isl1_q[i] == wr_pwc_isl1) && (pwc_root_q[i] == wr_root) &&
          (pwc_vpn2_q[i] == wr_vpn2) && (!wr_pwc_isl1 || (pwc_vpn1_q[i] == wr_vpn1))) begin
        pwc_has_match  = 1'b1;
        pwc_match_slot = PT_PWC_IDX_W'(i);
      end
      if (!pwc_valid_q[i]) begin
        pwc_has_inv  = 1'b1;
        pwc_inv_slot = PT_PWC_IDX_W'(i);
      end
    end
    pwc_evict   = !pwc_has_match && !pwc_has_inv;
    wr_pwc_slot = pwc_has_match ? pwc_match_slot : (pwc_has_inv ? pwc_inv_slot : pwc_rr_q);
  end

  // ---- 1RW SRAM banks for 4KB STLB (standalone ttg_sram_1rw primitive) ----
  for (genvar w = 0; w < PT_STLB_WAYS; w++) begin : g_stlb_sram
    wire bank_we = cpu_en && wr_stlb && !sfence_flush && (wr_stlb_way == PT_STLB_WAY_W'(w));
    wire bank_re = cpu_en && lk_rd_en;
    ttg_sram_1rw #(
      .DEPTH (PT_STLB_SETS),
      .WIDTH (STLB_ENTRY_W),
      .MASK_W(1),
      .TAG   ("L2TLB_STLB")
    ) u_sram (
      .clk  (clk), .rst_n(rst_n),
      .en   (bank_we || bank_re),
      .we   (bank_we),
      .addr (bank_we ? wr_stlb_idx : lk_rd_idx),
      .wdata(wr_stlb_entry),
      .wmask(1'b1),
      .rdata(stlb_rd_q[w])
    );
  end

  // ---- Resettable FF state: STLB valid/PLRU, SP CAM, PWC ----
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < PT_STLB_SETS; s++) begin
        stlb_valid_q[s] <= '0;
        stlb_plru_q[s]  <= 3'd0;
      end
      for (int i = 0; i < PT_SP_N; i++) begin
        sp_valid_q[i]  <= 1'b0;
        sp_global_q[i] <= 1'b0;
        sp_lvl_q[i]    <= '0;
        sp_root_q[i]   <= '0;
        sp_vpn2_q[i]   <= '0;
        sp_vpn1_q[i]   <= '0;
        sp_ppn_q[i]    <= '0;
        sp_perm_q[i]   <= '0;
      end
      sp_rr_q <= '0;
      for (int i = 0; i < PT_PWC_N; i++) begin
        pwc_valid_q[i] <= 1'b0;
        pwc_isl1_q[i]  <= 1'b0;
        pwc_root_q[i]  <= '0;
        pwc_vpn2_q[i]  <= '0;
        pwc_vpn1_q[i]  <= '0;
        pwc_ppn_q[i]   <= '0;
      end
      pwc_rr_q <= '0;
    end else if (cpu_en) begin
      if (sfence_flush) begin
        for (int s = 0; s < PT_STLB_SETS; s++) begin
          stlb_valid_q[s] <= '0;
          stlb_plru_q[s]  <= 3'd0;
        end
        for (int i = 0; i < PT_SP_N; i++) sp_valid_q[i] <= 1'b0;
        sp_rr_q <= '0;
        for (int i = 0; i < PT_PWC_N; i++) pwc_valid_q[i] <= 1'b0;
        pwc_rr_q <= '0;
      end else begin
        if (stlb_hit) begin
          stlb_plru_q[lk_idx] <= ttg_plru4_touch(stlb_plru_q[lk_idx], stlb_hit_way);
        end
        if (wr_stlb) begin
          stlb_valid_q[wr_stlb_idx][wr_stlb_way] <= 1'b1;
          stlb_plru_q[wr_stlb_idx]               <= ttg_plru4_touch(stlb_plru_q[wr_stlb_idx], wr_stlb_way);
        end
        if (wr_sp) begin
          sp_valid_q[wr_sp_slot]  <= 1'b1;
          sp_global_q[wr_sp_slot] <= wr_glob;
          sp_lvl_q[wr_sp_slot]    <= wr_level;
          sp_root_q[wr_sp_slot]   <= wr_root;
          sp_vpn2_q[wr_sp_slot]   <= wr_vpn2;
          sp_vpn1_q[wr_sp_slot]   <= wr_vpn1;
          sp_ppn_q[wr_sp_slot]    <= wr_ppn;
          sp_perm_q[wr_sp_slot]   <= wr_perm;
          if (sp_evict) sp_rr_q   <= sp_rr_q + PT_SP_IDX_W'(1);
        end
        if (wr_pwc) begin
          pwc_valid_q[wr_pwc_slot] <= 1'b1;
          pwc_isl1_q[wr_pwc_slot]  <= wr_pwc_isl1;
          pwc_root_q[wr_pwc_slot]  <= wr_root;
          pwc_vpn2_q[wr_pwc_slot]  <= wr_vpn2;
          pwc_vpn1_q[wr_pwc_slot]  <= wr_pwc_isl1 ? wr_vpn1 : '0;
          pwc_ppn_q[wr_pwc_slot]   <= wr_ppn;
          if (pwc_evict) pwc_rr_q  <= pwc_rr_q + PT_PWC_IDX_W'(1);
        end
      end
    end
  end

endmodule

`default_nettype wire
