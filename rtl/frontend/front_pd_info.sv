// Ref: front-end/front_top.cpp  FrontChecker::comb (log-depth parallel PdInfo: up to 1 history symbol & 1 RAS op)
`default_nettype none

module front_pd_info import ttg_cfg_pkg::*; import front_pkg::*; import bpu_stage_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    checked,
  input  logic                    flush,
  input  logic [XLEN_BITS-1:0]    slot_pc    [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  is_rvc,
  input  logic [31:0]             insts      [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  inst_valid,
  input  logic [1:0]              ptype      [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]    pre_target [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  dir_corrected,
  input  logic [FETCH_WIDTH-1:0]  predict_dir,
  input  logic [XLEN_BITS-1:0]    pd_next_pc,
  output logic                    pd_valid,
  output logic                    pd_flush,
  output logic                    pd_hn,
  output logic [HSYM_W-1:0]       pd_hbits,
  output logic [1:0]              pd_ras_op,
  output logic [XLEN_BITS-1:0]    pd_ras_val,
  output logic                    pd_nb_valid,
  output logic [XLEN_BITS-1:0]    pd_nb_pc
);

  // ---- False-branch detection (parallel ttg_first_set) ----
  logic [FETCH_WIDTH-1:0] nb_req, nb_oh;
  logic                   nb_any;
  logic [XLEN_BITS-1:0]   nb_pc_sel, nb_pc_d;

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++)
      nb_req[i] = flush && inst_valid[i] && predict_dir[i] && (ptype[i] == PREDECODE_NON_BRANCH);
  end
  ttg_first_set #(.N(FETCH_WIDTH)) u_nb (.req(nb_req), .onehot(nb_oh), .any(nb_any));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_nb_pc (.sel(nb_oh), .data(slot_pc), .out(nb_pc_sel));

  assign nb_pc_d = nb_any ? nb_pc_sel : '0;

  // ---- Parallel per-lane symbol & RAS op, then the first taken control lane (ttg_first_set) ----
  logic [FETCH_WIDTH-1:0] ctrl_tk, tk1_oh;
  logic                   tk1_any;
  logic [HSYM_W-1:0]      lane_sym  [FETCH_WIDTH];
  logic [1:0]             lane_rop  [FETCH_WIDTH];
  logic [XLEN_BITS-1:0]   lane_rval [FETCH_WIDTH];

  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++) begin
      logic [XLEN_BITS-1:0] tgt;
      ctrl_tk[i] = flush && inst_valid[i] && (ptype[i] != PREDECODE_NON_BRANCH) && dir_corrected[i];
      tgt          = (ptype[i] == PREDECODE_JALR) ? pd_next_pc : pre_target[i];
      lane_sym[i]  = hsym_of(slot_pc[i], tgt);
      lane_rop[i]  = 2'd0;
      lane_rval[i] = '0;
      if ((ptype[i] == PREDECODE_JAL) && (insts[i][11:7] == 5'd1)) begin
        lane_rop[i]  = 2'd1;
        lane_rval[i] = slot_pc[i] + (is_rvc[i] ? XLEN_BITS'(2) : XLEN_BITS'(4));
      end else if ((ptype[i] == PREDECODE_JALR) && (insts[i][11:7] == 5'd0) &&
                   (insts[i][19:15] == 5'd1) && (insts[i][31:20] == 12'd0)) begin
        lane_rop[i] = 2'd2;
      end
    end
  end

  ttg_first_set #(.N(FETCH_WIDTH)) u_tk (.req(ctrl_tk), .onehot(tk1_oh), .any(tk1_any));

  logic [HSYM_W-1:0]    sym1;
  logic [1:0]           rop1, ras_op_d;
  logic [XLEN_BITS-1:0] rval1, ras_val_d;

  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(HSYM_W))    u_sym1  (.sel(tk1_oh), .data(lane_sym),  .out(sym1));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(2))         u_rop1  (.sel(tk1_oh), .data(lane_rop),  .out(rop1));
  ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_rval1 (.sel(tk1_oh), .data(lane_rval), .out(rval1));

  always_comb begin
    ras_op_d  = 2'd0;
    ras_val_d = '0;
    if (tk1_any && (rop1 != 2'd0)) begin
      ras_op_d  = rop1;
      ras_val_d = rval1;
    end
  end

  logic                 pd_valid_q, pd_flush_q, pd_nb_valid_q, pd_hn_q;
  logic [1:0]           pd_ras_op_q;
  logic [HSYM_W-1:0]    pd_hbits_q;
  logic [XLEN_BITS-1:0] pd_ras_val_q, pd_nb_pc_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pd_valid_q    <= 1'b0;
      pd_flush_q    <= 1'b0;
      pd_hn_q       <= 1'b0;
      pd_hbits_q    <= '0;
      pd_ras_op_q   <= 2'd0;
      pd_ras_val_q  <= '0;
      pd_nb_valid_q <= 1'b0;
      pd_nb_pc_q    <= '0;
    end else begin
      pd_valid_q    <= checked;
      pd_flush_q    <= flush;
      pd_hn_q       <= tk1_any;
      pd_hbits_q    <= tk1_any ? sym1 : '0;
      pd_ras_op_q   <= ras_op_d;
      pd_ras_val_q  <= ras_val_d;
      pd_nb_valid_q <= nb_any;
      pd_nb_pc_q    <= nb_pc_d;
    end
  end

  assign pd_valid    = pd_valid_q;
  assign pd_flush    = pd_flush_q;
  assign pd_hn       = pd_hn_q;
  assign pd_hbits    = pd_hbits_q;
  assign pd_ras_op   = pd_ras_op_q;
  assign pd_ras_val  = pd_ras_val_q;
  assign pd_nb_valid = pd_nb_valid_q;
  assign pd_nb_pc    = pd_nb_pc_q;

endmodule

`default_nettype wire
