// Ref: front-end/BPU/BpuFtb.h  FtbTab (uFTB: 16x4 = 64-entry FF cold-start fallback for S0)
`default_nettype none

module bpu_uftb import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  // 0-cycle combinational S0 lookup
  input  logic [XLEN_BITS-1:0] rd_base,
  output logic                 rd_hit,
  output ftb_ent_t             rd_ent,
  // 1-cycle commit update (taken-only alloc, 20b compressed target range)
  input  logic                 upd_en,
  input  logic [XLEN_BITS-1:0] upd_base,
  input  ftb_br_upd_t          upd_br,
  // Predecode false-branch slot clear
  input  logic                 clr_en,
  input  logic [XLEN_BITS-1:0] clr_base,
  input  logic [XLEN_BITS-1:0] clr_pc
);

  localparam int SETS  = FTB_S0_SETS;
  localparam int WAYS  = FTB_S0_WAYS;
  localparam int SET_W = $clog2(SETS);
  localparam int WAY_W = $clog2(WAYS);

  typedef ftb_ent_t [WAYS-1:0] set_t;

  function automatic logic [SET_W-1:0] set_idx(input logic [XLEN_BITS-1:0] pc);
    logic [31:0] w;
    w = 32'(pc >> SLOT_SHIFT);
    return SET_W'(w ^ (w >> SET_W));
  endfunction

  function automatic logic [FTB_MAX_TAG_W-1:0] norm_tag(input logic [XLEN_BITS-1:0] pc);
    logic [31:0] w, mask;
    w    = 32'(pc >> SLOT_SHIFT);
    mask = (32'd1 << FTB_S0_TAG_W) - 32'd1;
    return FTB_MAX_TAG_W'((w >> SET_W) & mask);
  endfunction

  set_t ff_mem_q [SETS];
  logic [SET_W-1:0]         rd_s, upd_s, clr_s;
  logic [FTB_MAX_TAG_W-1:0] upd_tg, clr_tg;
  logic                     tgt_ok, hit_found, inv_found, do_upd, do_clr, any_slot_v;
  logic [WAY_W-1:0]         hit_w, inv_w, sel_w, plru_vic;
  ftb_ent_t                 cur_ent;
  ftb_upsert_res_t          up_res;
  set_t                     upd_set_next, clr_set_next;

  assign rd_s   = set_idx(rd_base);
  assign upd_s  = set_idx(upd_base);
  assign clr_s  = set_idx(clr_base);
  assign upd_tg = norm_tag(upd_base);
  assign clr_tg = norm_tag(clr_base);

  bpu_plru #(.SETS(SETS), .WAYS(WAYS)) u_plru (
    .clk, .rst_n,
    .rd_set    (upd_s),
    .victim_way(plru_vic),
    .touch_en  (do_upd && any_slot_v),
    .touch_set (upd_s),
    .touch_way (sel_w)
  );

  always_comb begin
    set_t s_cur;
    s_cur     = ff_mem_q[upd_s];
    tgt_ok    = !upd_br.actual_dir || (upd_br.br_type == BR_RET) || ftb_s0_tgt_fits(upd_base, upd_br.target);
    hit_found = 1'b0; hit_w = '0;
    inv_found = 1'b0; inv_w = '0;
    for (int w = 0; w < WAYS; w++) begin
      if (!hit_found && s_cur[w].valid && (s_cur[w].tag == upd_tg)) begin
        hit_found = 1'b1; hit_w = WAY_W'(w);
      end
      if (!inv_found && !s_cur[w].valid) begin
        inv_found = 1'b1; inv_w = WAY_W'(w);
      end
    end
    do_upd = upd_en && tgt_ok && (hit_found || upd_br.actual_dir);
    sel_w  = hit_found ? hit_w : (inv_found ? inv_w : plru_vic);
    if (hit_found) begin
      cur_ent = s_cur[hit_w];
    end else begin
      cur_ent       = '0;
      cur_ent.valid = 1'b1;
      cur_ent.tag   = upd_tg;
    end
    up_res     = ftb_upsert_branch(cur_ent, upd_br);
    any_slot_v = 1'b0;
    for (int k = 0; k < FTB_SLOTS; k++) if (up_res.ent.s[k].valid) any_slot_v = 1'b1;

    upd_set_next = s_cur;
    if (do_upd) begin
      upd_set_next[sel_w] = up_res.ent;
      if (!any_slot_v) upd_set_next[sel_w].valid = 1'b0;
    end

    // Predecode false-branch slot clear
    clr_set_next = ff_mem_q[clr_s];
    do_clr       = 1'b0;
    begin
      logic clr_car, clr_vok, c_hit, s_any;
      logic [3:0] clr_off;
      clr_car = (clr_pc + XLEN_BITS'(SLOT_BYTES) == clr_base);
      clr_vok = clr_car || (clr_pc >= clr_base);
      clr_off = clr_car ? 4'd0 : 4'((clr_pc - clr_base) >> SLOT_SHIFT);
      c_hit   = 1'b0;
      s_any   = 1'b0;
      if (clr_en && clr_vok) begin
        for (int w = 0; w < WAYS; w++) begin
          if (!c_hit && clr_set_next[w].valid && (clr_set_next[w].tag == clr_tg)) begin
            c_hit = 1'b1;
            s_any = 1'b0;
            for (int k = 0; k < FTB_SLOTS; k++) begin
              if (clr_set_next[w].s[k].valid && (clr_set_next[w].s[k].offset == clr_off))
                clr_set_next[w].s[k] = '0;
              else if (clr_set_next[w].s[k].valid)
                s_any = 1'b1;
            end
            if (!s_any) clr_set_next[w].valid = 1'b0;
          end
        end
      end
      do_clr = clr_en && c_hit;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < SETS; i++) ff_mem_q[i] <= '0;
    end else begin
      if (do_upd) ff_mem_q[upd_s] <= upd_set_next;
      if (do_clr) ff_mem_q[clr_s] <= clr_set_next;
    end
  end

  always_comb begin
    logic [FTB_MAX_TAG_W-1:0] t0;
    set_t s0;
    s0     = ff_mem_q[rd_s];
    t0     = norm_tag(rd_base);
    rd_hit = 1'b0;
    rd_ent = '0;
    for (int w = 0; w < WAYS; w++) begin
      if (!rd_hit && s0[w].valid && (s0[w].tag == t0)) begin
        rd_hit = 1'b1;
        rd_ent = s0[w];
      end
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^{up_res.slot_found, up_res.slot_idx, up_res.slot_ctr,
                       upd_br.pred_dir, upd_br.alt_pred, upd_br.pcpn};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
