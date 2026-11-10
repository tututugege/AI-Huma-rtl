// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::main_read, apply_table_update (type, TAGE and BTB/ITT banks)
`default_nettype none

// The arrays of the main predictor: type predictor, TAGE and BTB / ITT, one bank per slot position (bank = pc[4:2]).
//   S1  the block's slots read their banks (the slot of bank b is the pc of the block with pc[4:2] == b); the raw
//       array data leave the module to be registered into S2.
//   S2  the TAGE banks do their compare / select (provider, alternate, use-alt counter of the bank).
//   update  the write ports of the update queue: at most one entry per bank and cycle.
module bpu_banks import bpu_pkg::*; import bpu_btb_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  // S1 read
  input  logic [31:0]         s1_base,
  input  tix_all_t            s1_tix,
  output raw_all_t            s1_raw,
  // S2 TAGE select
  input  raw_all_t            s2_raw,
  input  tix_all_t            s2_tix,
  output logic [NBANK-1:0]    s2_pred,
  output logic [NBANK-1:0]    s2_alt,
  output logic [PCPN_W-1:0]   s2_pcpn    [NBANK],
  output logic [PCPN_W-1:0]   s2_altpcpn [NBANK],
  // update ports (slot bank)
  input  logic [NBANK-1:0]    wr_valid,
  input  upd_ent_t            wr_ent     [NBANK]
);

  logic [31:0]  slot_pc  [NBANK];     // pc of the block's slot that lives in bank b
  logic [31:0]  wr_pc    [NBANK];
  tp_entry_t    ty_rd    [NBANK][TP_WAYS];
  logic [2:0]   wr_ty    [NBANK];

  always_comb begin
    for (int b = 0; b < NBANK; b++) begin
      slot_pc[b] = s1_base + 32'(4 * ((b - int'(s1_base[BANK_W + 1:2])) & (NBANK - 1)));
      wr_pc[b]   = wr_ent[b].pc;
      wr_ty[b]   = wr_ent[b].ty;
    end
  end

  bpu_type u_type (
    .clk, .rst_n, .rd_pc(slot_pc), .rd_way(ty_rd), .upd_valid(wr_valid), .upd_pc(wr_pc), .upd_br_type(wr_ty)
  );

  for (genvar b = 0; b < NBANK; b++) begin : g_bank
    tg_raw_t               tg_rd;
    btb_ent_t              btb_rd [B_WAYS];
    itt_ent_t [NITT-1:0]   itt_rd;
    logic                  tg_en;
    logic [T_TAG_W-1:0]    upd_tag [TN];
    logic [T_IDX_W-1:0]    upd_idx [TN];
    logic [NITT-1:0][T_TAG_W-1:0]   upd_itt_tag;
    logic [NITT-1:0][ITT_IDX_W-1:0] upd_itt_idx;
    logic [NITT-1:0][ITT_IDX_W-1:0] rd_itt_idx;

    always_comb begin
      tg_en = wr_valid[b] && (wr_ent[b].ty == BR_DIRECT);
      for (int t = 0; t < TN; t++) begin
        upd_tag[t] = wr_ent[b].tag[t];
        upd_idx[t] = wr_ent[b].idx[t];
      end
      for (int k = 0; k < NITT; k++) begin
        upd_itt_tag[k] = wr_ent[b].tag[ITT_TBL[k]];
        upd_itt_idx[k] = ITT_IDX_W'(wr_ent[b].idx[ITT_TBL[k]]);
        rd_itt_idx[k]  = ITT_IDX_W'(s1_tix[b].idx[ITT_TBL[k]]);
      end
    end

    bpu_tage_bank u_tage (
      .clk, .rst_n, .rd_base(s1_tix[b].base), .rd_idx(s1_tix[b].idx), .rd_raw(tg_rd), .sel_raw(s2_raw[b].tg),
      .sel_tag_in(s2_tix[b].tag),
      .sel_pred(s2_pred[b]), .sel_alt_pred(s2_alt[b]), .sel_pcpn(s2_pcpn[b]), .sel_altpcpn(s2_altpcpn[b]),
      .update_en(tg_en), .upd_pc_idx(wr_pc[b][T_BASE_W + BANK_W + 2 - 1:BANK_W + 2]), .real_dir(wr_ent[b].dir),
      .pred_in(tg_en && wr_ent[b].pred), .alt_pred_in(tg_en && wr_ent[b].alt), .pcpn_in(wr_ent[b].pcpn),
      .tag_in(upd_tag), .idx_in(upd_idx)
    );

    bpu_btb_bank u_btb (
      .clk, .rst_n, .rd_pc(slot_pc[b][31:BANK_W]), .rd_itt_idx,
      .rd_btb(btb_rd), .rd_itt(itt_rd), .upd_valid(wr_valid[b]), .upd_pc(wr_pc[b][31:BANK_W]),
      .upd_actual_addr(wr_ent[b].tgt), .upd_br_type_in(wr_ent[b].ty), .upd_actual_dir(wr_ent[b].dir),
      .upd_itt_idx, .upd_itt_tag
    );

    always_comb begin
      s1_raw[b].ty  = {ty_rd[b][1], ty_rd[b][0]};
      s1_raw[b].tg  = tg_rd;
      s1_raw[b].btb = {btb_rd[3], btb_rd[2], btb_rd[1], btb_rd[0]};
      s1_raw[b].itt = itt_rd;
    end
  end

endmodule

`default_nettype wire
