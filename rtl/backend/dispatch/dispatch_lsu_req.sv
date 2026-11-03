// Ref: back-end/Dispatch.cpp  Dispatch::comb_fire (steps 3 and 4: STQ / LDQ allocation requests)
`default_nettype none

// Drives the LSU allocation ports for the lanes that fired: the store (or load) granted request port k
// in comb_alloc sends its ROB index, branch mask and queue metadata on port k.
module dispatch_lsu_req
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
(
  input  logic                      fire        [NUM_SLOTS],
  input  logic [STQ_PORTS-1:0]      st_port_sel [NUM_SLOTS],
  input  logic [LDQ_PORTS-1:0]      ld_port_sel [NUM_SLOTS],
  input  dis_inst_t                 inst        [NUM_SLOTS],   // for br_mask, func3
  input  dis_res_t                  res         [NUM_SLOTS],
  output logic                      st_req      [STQ_PORTS],
  output logic [BR_MASK_WIDTH-1:0]  st_br_mask  [STQ_PORTS],
  output logic [2:0]                st_func3    [STQ_PORTS],
  output logic [ROB_IDX_WIDTH-1:0]  st_rob_idx  [STQ_PORTS],
  output logic                      st_rob_flag [STQ_PORTS],
  output logic                      st_stq_flag [STQ_PORTS],
  output logic                      ld_req      [LDQ_PORTS],
  output logic [LDQ_IDX_WIDTH-1:0]  ld_idx      [LDQ_PORTS],
  output logic [BR_MASK_WIDTH-1:0]  ld_br_mask  [LDQ_PORTS],
  output logic [ROB_IDX_WIDTH-1:0]  ld_rob_idx  [LDQ_PORTS],
  output logic                      ld_rob_flag [LDQ_PORTS]
);

  // Ref: Dispatch::comb_fire step 3 (STQ ports)
  for (genvar k = 0; k < STQ_PORTS; k++) begin : g_stq_port
    logic [NUM_SLOTS-1:0] owner;
    logic [BR_MASK_WIDTH-1:0] sel_br_mask [NUM_SLOTS];
    logic [ROB_IDX_WIDTH + 3 + 2 - 1:0] sel_meta [NUM_SLOTS];   // {rob_idx, func3, rob_flag, stq_flag}
    logic [ROB_IDX_WIDTH + 3 + 2 - 1:0] meta;
    always_comb begin
      for (int i = 0; i < NUM_SLOTS; i++) begin
        owner[i]       = fire[i] && st_port_sel[i][k];
        sel_br_mask[i] = inst[i].br_mask;
        sel_meta[i]    = {res[i].rob_idx, inst[i].func3, res[i].rob_flag, res[i].stq_flag};
      end
      st_req[k] = |owner;
    end
    ttg_onehot_mux #(.N(NUM_SLOTS), .W(BR_MASK_WIDTH)) u_br (.sel(owner), .data(sel_br_mask), .out(st_br_mask[k]));
    ttg_onehot_mux #(.N(NUM_SLOTS), .W(ROB_IDX_WIDTH + 5)) u_meta (.sel(owner), .data(sel_meta), .out(meta));
    always_comb begin
      {st_rob_idx[k], st_func3[k], st_rob_flag[k], st_stq_flag[k]} = meta;
    end
  end

  // Ref: Dispatch::comb_fire step 4 (LDQ ports)
  for (genvar k = 0; k < LDQ_PORTS; k++) begin : g_ldq_port
    logic [NUM_SLOTS-1:0] owner;
    logic [BR_MASK_WIDTH-1:0] sel_br_mask [NUM_SLOTS];
    logic [LDQ_IDX_WIDTH + ROB_IDX_WIDTH + 1 - 1:0] sel_meta [NUM_SLOTS];   // {ldq_idx, rob_idx, rob_flag}
    logic [LDQ_IDX_WIDTH + ROB_IDX_WIDTH + 1 - 1:0] meta;
    always_comb begin
      for (int i = 0; i < NUM_SLOTS; i++) begin
        owner[i]       = fire[i] && ld_port_sel[i][k];
        sel_br_mask[i] = inst[i].br_mask;
        sel_meta[i]    = {res[i].ldq_idx, res[i].rob_idx, res[i].rob_flag};
      end
      ld_req[k] = |owner;
    end
    ttg_onehot_mux #(.N(NUM_SLOTS), .W(BR_MASK_WIDTH)) u_br (.sel(owner), .data(sel_br_mask), .out(ld_br_mask[k]));
    ttg_onehot_mux #(.N(NUM_SLOTS), .W(LDQ_IDX_WIDTH + ROB_IDX_WIDTH + 1)) u_meta (
      .sel(owner), .data(sel_meta), .out(meta));
    always_comb begin
      {ld_idx[k], ld_rob_idx[k], ld_rob_flag[k]} = meta;
    end
  end

endmodule

`default_nettype wire
