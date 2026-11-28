// Ref: front-end/BPU/BpuFtb.h  FtbTab / mirror_ent_to_ftb0 (uFTB: 64x4=256 compact FF, FastFill)
`default_nettype none

module bpu_uftb import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; (
  input  logic                 clk,
  input  logic                 rst_n,
  // 0-cycle combinational S0 lookup
  input  logic [XLEN_BITS-1:0] rd_base,
  output logic                 rd_hit,
  output ftb_ent_t             rd_ent,
  // Single muxed write port (Priority: commit mirror > S2 FastFill)
  input  logic                 wr_en,
  input  logic [XLEN_BITS-1:0] wr_base,
  input  ftb_ent_t             wr_ent,
  input  logic                 wr_has_taken,
  // Predecode false-branch slot clear
  input  logic                 clr_en,
  input  logic [XLEN_BITS-1:0] clr_base,
  input  logic [XLEN_BITS-1:0] clr_pc
);

  localparam int SETS  = FTB_S0_SETS;
  localparam int WAYS  = FTB_S0_WAYS;
  localparam int SET_W = $clog2(SETS);
  localparam int WAY_W = $clog2(WAYS);

  typedef uftb_ent_t [WAYS-1:0] uset_t;

  function automatic logic [SET_W-1:0] set_idx(input logic [XLEN_BITS-1:0] pc);
    logic [31:0] w;
    w = 32'(pc >> SLOT_SHIFT);
    return SET_W'(w ^ (w >> SET_W));
  endfunction

  function automatic logic [FTB_S0_TAG_W-1:0] norm_tag(input logic [XLEN_BITS-1:0] pc);
    logic [31:0] w, mask;
    w    = 32'(pc >> SLOT_SHIFT);
    mask = (32'd1 << FTB_S0_TAG_W) - 32'd1;
    return FTB_S0_TAG_W'((w >> SET_W) & mask);
  endfunction

  uset_t ff_mem_q [SETS];
  logic [SET_W-1:0]        rd_s, wr_s, clr_s;
  logic [FTB_S0_TAG_W-1:0] rd_tg, wr_tg, clr_tg;
  logic                    hit_found, inv_found, any_slot_v, do_wr, do_touch, do_clr;
  logic [WAY_W-1:0]        hit_w, inv_w, sel_w, plru_vic;
  uftb_ent_t               cand_ent;
  uset_t                   wr_set_next, clr_set_next;

  assign rd_s   = set_idx(rd_base);
  assign wr_s   = set_idx(wr_base);
  assign clr_s  = set_idx(clr_base);
  assign rd_tg  = norm_tag(rd_base);
  assign wr_tg  = norm_tag(wr_base);
  assign clr_tg = norm_tag(clr_base);

  bpu_plru #(.SETS(SETS), .WAYS(WAYS)) u_plru (
    .clk, .rst_n,
    .rd_set    (wr_s),
    .victim_way(plru_vic),
    .touch_en  (do_touch),
    .touch_set (wr_s),
    .touch_way (sel_w)
  );

  // Ref: BpuFtb::mirror_ent_to_ftb0 (commit mirror or S2 FastFill)
  always_comb begin
    uset_t s_cur;
    s_cur          = ff_mem_q[wr_s];
    cand_ent       = '0;
    cand_ent.valid = 1'b1;
    cand_ent.tag   = wr_tg;
    any_slot_v     = 1'b0;
    for (int k = 0; k < FTB_SLOTS; k++) begin
      if (wr_ent.s[k].valid &&
          ((wr_ent.s[k].br_type == BR_RET) || ftb_s0_tgt_fits(wr_base, sv39_unpack(wr_ent.s[k].target)))) begin
        cand_ent.s[k] = '{
          valid:   1'b1,
          offset:  wr_ent.s[k].offset,
          carried: wr_ent.s[k].carried,
          is_rvc:  wr_ent.s[k].is_rvc,
          br_type: wr_ent.s[k].br_type,
          ctr:     wr_ent.s[k].ctr,
          tgt20:   wr_ent.s[k].target[FTB_S0_TGT_B-1:0]
        };
        any_slot_v = 1'b1;
      end
    end

    hit_found = 1'b0; hit_w = '0;
    inv_found = 1'b0; inv_w = '0;
    for (int w = 0; w < WAYS; w++) begin
      if (!hit_found && s_cur[w].valid && (s_cur[w].tag == wr_tg)) begin
        hit_found = 1'b1; hit_w = WAY_W'(w);
      end
      if (!inv_found && !s_cur[w].valid) begin
        inv_found = 1'b1; inv_w = WAY_W'(w);
      end
    end

    sel_w       = hit_found ? hit_w : (inv_found ? inv_w : plru_vic);
    wr_set_next = s_cur;
    do_wr       = 1'b0;
    do_touch    = 1'b0;
    if (wr_en) begin
      if (hit_found) begin
        do_wr = 1'b1;
        if (any_slot_v) begin
          wr_set_next[hit_w] = cand_ent;
          do_touch           = 1'b1;
        end else begin
          wr_set_next[hit_w].valid = 1'b0;
        end
      end else if (wr_has_taken && any_slot_v) begin
        do_wr              = 1'b1;
        do_touch           = 1'b1;
        wr_set_next[sel_w] = cand_ent;
      end
    end
  end

  // Ref: BpuFtb::clear_false_branch_ftb0 (applied after commit/FastFill write on set match)
  always_comb begin
    logic clr_car, clr_vok, c_hit, s_any;
    logic [3:0] clr_off;
    clr_set_next = (do_wr && (clr_s == wr_s)) ? wr_set_next : ff_mem_q[clr_s];
    clr_car      = (clr_pc + XLEN_BITS'(SLOT_BYTES) == clr_base);
    clr_vok      = clr_car || (clr_pc >= clr_base);
    clr_off      = clr_car ? 4'd0 : 4'((clr_pc - clr_base) >> SLOT_SHIFT);
    c_hit        = 1'b0;
    s_any        = 1'b0;
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

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < SETS; i++) ff_mem_q[i] <= '0;
    end else begin
      if (do_wr)  ff_mem_q[wr_s]  <= wr_set_next;
      if (do_clr) ff_mem_q[clr_s] <= clr_set_next;
    end
  end

  // Combinational S0 lookup & 38b Sv39 packed target reconstruction
  always_comb begin
    uset_t     s0;
    /* verilator lint_off UNUSEDSIGNAL */
    uftb_ent_t m;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [FTB_VA_BITS-FTB_S0_TGT_B-1:0] base_hi;
    s0      = ff_mem_q[rd_s];
    base_hi = rd_base[FTB_VA_BITS : FTB_S0_TGT_B + SLOT_SHIFT];
    rd_hit  = 1'b0;
    m       = '0;
    for (int w = 0; w < WAYS; w++) begin
      if (!rd_hit && s0[w].valid && (s0[w].tag == rd_tg)) begin
        rd_hit = 1'b1;
        m      = s0[w];
      end
    end
    rd_ent       = '0;
    rd_ent.valid = rd_hit;
    rd_ent.tag   = FTB_MAX_TAG_W'(m.tag);
    for (int k = 0; k < FTB_SLOTS; k++) begin
      rd_ent.s[k] = '{
        valid:   m.s[k].valid,
        offset:  m.s[k].offset,
        carried: m.s[k].carried,
        is_rvc:  m.s[k].is_rvc,
        br_type: m.s[k].br_type,
        ctr:     m.s[k].ctr,
        target:  {base_hi, m.s[k].tgt20}
      };
    end
  end

  logic unused_ok;
  assign unused_ok = ^{wr_ent.valid, wr_ent.tag, rd_base[XLEN_BITS-1:FTB_VA_BITS+1],
                       rd_base[FTB_S0_TGT_B:0]};

endmodule
`default_nettype wire
