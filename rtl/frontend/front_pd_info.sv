// Ref: front-end/front_top.cpp  FrontChecker::comb (PdInfo: up to 2 history symbols & 2 RAS ops, pd_nb_base)
`default_nettype none

module front_pd_info import ttg_cfg_pkg::*; import front_pkg::*; import bpu_stage_pkg::*; (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    checked,
  input  logic                    flush,
  input  logic                    multi,
  input  logic [4:0]              keep_n,
  input  logic [FETCH_WIDTH-1:0]  seg_first,
  input  logic [XLEN_BITS-1:0]    slot_pc    [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]    ptab_pc    [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  is_rvc,
  input  logic [31:0]             insts      [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  inst_valid,
  input  logic [1:0]              ptype      [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]    pre_target [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]  dir_corrected,
  input  logic [FETCH_WIDTH-1:0]  predict_dir,
  input  logic [XLEN_BITS-1:0]    ptab_next,
  output logic                    pd_valid,
  output logic                    pd_flush,
  output logic [1:0]              pd_hn,
  output logic [5:0]              pd_hbits,
  output logic [1:0]              pd_ras_op,
  output logic [XLEN_BITS-1:0]    pd_ras_val,
  output logic [1:0]              pd_ras_op2,
  output logic [XLEN_BITS-1:0]    pd_ras_val2,
  output logic                    pd_nb_valid,
  output logic [XLEN_BITS-1:0]    pd_nb_pc,
  output logic [XLEN_BITS-1:0]    pd_nb_base
);

  logic                 nb_any;
  logic [XLEN_BITS-1:0] nb_pc_d, nb_base_d;
  logic [1:0]           hn_d, ras_op_d, ras_op2_d;
  logic [5:0]           hbits_d;
  logic [XLEN_BITS-1:0] ras_val_d, ras_val2_d;

  // False-branch (predicted taken on non-branch) detection with segment base for multi
  always_comb begin
    logic [XLEN_BITS-1:0] seg_base;
    nb_any    = 1'b0;
    nb_pc_d   = '0;
    nb_base_d = '0;
    seg_base  = ptab_pc[0];
    if (flush) begin
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        if (seg_first[i]) seg_base = ptab_pc[i];
        if (!nb_any && inst_valid[i] && predict_dir[i] && (ptype[i] == PREDECODE_NON_BRANCH)) begin
          nb_any    = 1'b1;
          nb_pc_d   = slot_pc[i];
          nb_base_d = multi ? seg_base : '0;
        end
      end
    end
  end

  // Up to 2 corrected taken control instructions (Block A + optional Block B)
  always_comb begin
    logic stop;
    logic [XLEN_BITS-1:0] tgt, rval;
    logic [HSYM_W-1:0]    sym;
    logic [1:0]           rop;
    hn_d       = 2'd0;
    hbits_d    = 6'd0;
    ras_op_d   = 2'd0;
    ras_val_d  = '0;
    ras_op2_d  = 2'd0;
    ras_val2_d = '0;
    stop       = 1'b0;
    tgt        = '0;
    rval       = '0;
    sym        = '0;
    rop        = 2'd0;
    if (flush) begin
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        if (!stop && (!multi || (5'(i) < keep_n))) begin
          if (inst_valid[i] && (ptype[i] != PREDECODE_NON_BRANCH) && dir_corrected[i]) begin
            if (ptype[i] == PREDECODE_JALR)
              tgt = (multi && (i + 1 < FETCH_WIDTH) && seg_first[i + 1]) ? slot_pc[i + 1] : ptab_next;
            else
              tgt = pre_target[i];
            sym = hsym_of(slot_pc[i], tgt);
            if (hn_d == 2'd0)      begin hbits_d[2:0] = sym; hn_d = 2'd1; end
            else if (hn_d == 2'd1) begin hbits_d[5:3] = sym; hn_d = 2'd2; end

            rop  = 2'd0;
            rval = '0;
            if ((ptype[i] == PREDECODE_JAL) && (insts[i][11:7] == 5'd1)) begin
              rop  = 2'd1;
              rval = slot_pc[i] + (is_rvc[i] ? XLEN_BITS'(2) : XLEN_BITS'(4));
            end else if ((ptype[i] == PREDECODE_JALR) && (insts[i][11:7] == 5'd0) &&
                         (insts[i][19:15] == 5'd1) && (insts[i][31:20] == 12'd0)) begin
              rop = 2'd2;
            end
            if (rop != 2'd0) begin
              if (ras_op_d == 2'd0)       begin ras_op_d  = rop; ras_val_d  = rval; end
              else if (ras_op2_d == 2'd0) begin ras_op2_d = rop; ras_val2_d = rval; end
            end
            if (!multi || (5'(i + 1) >= keep_n)) stop = 1'b1;
          end
        end
      end
    end
  end

  logic                 pd_valid_q, pd_flush_q, pd_nb_valid_q;
  logic [1:0]           pd_hn_q, pd_ras_op_q, pd_ras_op2_q;
  logic [5:0]           pd_hbits_q;
  logic [XLEN_BITS-1:0] pd_ras_val_q, pd_ras_val2_q, pd_nb_pc_q, pd_nb_base_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pd_valid_q    <= 1'b0;
      pd_flush_q    <= 1'b0;
      pd_hn_q       <= 2'd0;
      pd_hbits_q    <= 6'd0;
      pd_ras_op_q   <= 2'd0;
      pd_ras_val_q  <= '0;
      pd_ras_op2_q  <= 2'd0;
      pd_ras_val2_q <= '0;
      pd_nb_valid_q <= 1'b0;
      pd_nb_pc_q    <= '0;
      pd_nb_base_q  <= '0;
    end else begin
      pd_valid_q    <= checked;
      pd_flush_q    <= flush;
      pd_hn_q       <= hn_d;
      pd_hbits_q    <= hbits_d;
      pd_ras_op_q   <= ras_op_d;
      pd_ras_val_q  <= ras_val_d;
      pd_ras_op2_q  <= ras_op2_d;
      pd_ras_val2_q <= ras_val2_d;
      pd_nb_valid_q <= nb_any;
      pd_nb_pc_q    <= nb_pc_d;
      pd_nb_base_q  <= nb_base_d;
    end
  end

  assign pd_valid    = pd_valid_q;
  assign pd_flush    = pd_flush_q;
  assign pd_hn       = pd_hn_q;
  assign pd_hbits    = pd_hbits_q;
  assign pd_ras_op   = pd_ras_op_q;
  assign pd_ras_val  = pd_ras_val_q;
  assign pd_ras_op2  = pd_ras_op2_q;
  assign pd_ras_val2 = pd_ras_val2_q;
  assign pd_nb_valid = pd_nb_valid_q;
  assign pd_nb_pc    = pd_nb_pc_q;
  assign pd_nb_base  = pd_nb_base_q;

endmodule

`default_nettype wire
