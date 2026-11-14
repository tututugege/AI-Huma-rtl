// Ref: front-end/front_top.cpp  FrontComb::write_ptab_and_check (RVC=1 block: carry assembly, instruction starts, straddler)
`default_nettype none

// RVC=1 (C910-style carry): the checked fetch group as the instruction queue holds it is corrected before the
// predecode check:
//  - if the previous group ended with a 32-bit instruction whose first halfword it carried (lh_*), slot 0 of this group
//    is the second halfword: the instruction is assembled ({raw0, carried halfword}, pc = group pc - SLOT_BYTES), put in
//    slot 0 and predecoded again; the instruction starts then follow the chain from slot 1 (start_b);
//  - slots that do not start an instruction are invalid;
//  - a 32-bit instruction that starts in the last slot of the group is delivered complete when the BPU predicted it taken
//    and the window of the slot has its upper halfword (same cache line): the fetch has already moved on to the target,
//    nothing would ever complete it otherwise.  The sequential continuation of the group is then behind the instruction;
//  - any other such instruction cannot be completed from this group: it is not delivered, its first halfword leaves for
//    the carry register (straddle / carry_low).
// With RVC=0 the group passes unchanged.
module front_head_fix import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic [XLEN_BITS-1:0]            base_pc,
  input  logic [31:0]                     insts_i  [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]          valid_i,
  input  logic [FETCH_WIDTH-1:0]          page_fault,
  input  logic [1:0]                      ptype_i  [FETCH_WIDTH],
  input  logic [XLEN_BITS-1:0]            ptarget_i [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]          is_rvc_i,
  input  logic [FETCH_WIDTH-1:0]          start_a,
  input  logic [FETCH_WIDTH-1:0]          start_b,
  input  logic [15:0]                     raw0,
  input  logic [FETCH_WIDTH-1:0]          predict_dir,   // the PTAB's prediction
  input  logic                            up_ok,         // the last slot's window has its upper halfword
  input  logic [XLEN_BITS-1:0]            seq_next_i,    // the group's sequential continuation (instruction queue)
  input  logic                            lh_valid,
  input  logic [XLEN_BITS-1:0]            lh_pc,
  input  logic [15:0]                     lh_data,
  output logic [31:0]                     insts_o  [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]          valid_o,
  output logic [1:0]                      ptype_o  [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0]            ptarget_o [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0]          is_rvc_o,
  output logic                            carry,         // slot 0 is the assembled instruction
  output logic [XLEN_BITS-1:0]            pc0,           // pc of slot 0
  output logic                            straddle,      // the last slot of the group starts an undelivered 32-bit instruction
  output logic [15:0]                     carry_low,     // ... and this is its first halfword
  output logic [XLEN_BITS-1:0]            group_end_pc,  // pc after the last valid slot of the group (before this correction)
  output logic [XLEN_BITS-1:0]            seq_next_o     // the group's sequential continuation (after this correction)
);

  if (RVC_ENABLE == 0) begin : g_pass
    always_comb begin
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        insts_o[i]   = insts_i[i];
        ptype_o[i]   = ptype_i[i];
        ptarget_o[i] = ptarget_i[i];
      end
    end
    assign valid_o      = valid_i;
    assign is_rvc_o     = '0;
    assign carry        = 1'b0;
    assign pc0          = base_pc;
    assign straddle     = 1'b0;
    assign carry_low    = '0;
    assign group_end_pc = '0;
    assign seq_next_o   = seq_next_i;
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_rvc;
    assign unused_rvc = ^{page_fault, is_rvc_i, start_a, start_b, raw0, lh_valid, lh_pc, lh_data, predict_dir, up_ok};
    /* verilator lint_on UNUSEDSIGNAL */
  end else begin : g_rvc
    logic [XLEN_BITS-1:0] asm_pc;
    logic [31:0]          asm_word;
    logic [1:0]           asm_type;
    logic [XLEN_BITS-1:0] asm_tgt;
    logic [FETCH_WIDTH-1:0] chain, last_oh, straddle_oh, straddle_raw_oh, complete_oh, keep;
    logic [XLEN_BITS-1:0]   slot_pc [FETCH_WIDTH];
    logic [XLEN_BITS-1:0]   complete_pc;
    logic [15:0]          straddle_data [FETCH_WIDTH];
    logic [FETCH_WIDTH-1:0] lane_invalid, first_invalid_oh;
    logic                 any_invalid;
    logic [$clog2(FETCH_WIDTH)-1:0] first_invalid_idx;
    logic [$clog2(FETCH_WIDTH + 1)-1:0] rvc_n;

    assign carry    = lh_valid && (lh_pc == base_pc) && valid_i[0];
    assign asm_pc   = base_pc - XLEN_BITS'(SLOT_BYTES);
    assign asm_word = {raw0, lh_data};
    assign pc0      = carry ? asm_pc : base_pc;

    predecode_lane u_asm (
      .pc(asm_pc), .inst(asm_word), .inst_valid(1'b1),
      .predecode_type(asm_type), .predecode_target_address(asm_tgt));

    // valid prefix of the group (the slots the instruction queue entry holds)
    always_comb begin
      for (int i = 0; i < FETCH_WIDTH; i++) lane_invalid[i] = !valid_i[i];
    end
    ttg_first_set #(.N(FETCH_WIDTH)) u_first_invalid (.req(lane_invalid), .onehot(first_invalid_oh), .any(any_invalid));
    ttg_onehot_to_idx #(.N(FETCH_WIDTH)) u_first_invalid_idx (.onehot(first_invalid_oh), .idx(first_invalid_idx));
    assign rvc_n        = any_invalid ? ($clog2(FETCH_WIDTH + 1))'(first_invalid_idx) : ($clog2(FETCH_WIDTH + 1))'(FETCH_WIDTH);
    assign group_end_pc = base_pc + XLEN_BITS'(rvc_n) * XLEN_BITS'(SLOT_BYTES);

    always_comb begin
      chain = carry ? start_b : start_a;
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        last_oh[i]     = valid_i[i] && ((i == FETCH_WIDTH - 1) ? 1'b1 : !valid_i[i+1]);
        straddle_raw_oh[i] = last_oh[i] && chain[i] && !is_rvc_i[i] && !page_fault[i];
        complete_oh[i] = straddle_raw_oh[i] && predict_dir[i] && up_ok;
        straddle_oh[i] = straddle_raw_oh[i] && !complete_oh[i];
        slot_pc[i]     = base_pc + XLEN_BITS'(SLOT_BYTES * i);
        keep[i]        = valid_i[i] && (chain[i] || (carry && i == 0));
        valid_o[i]     = keep[i] && !straddle_oh[i];
        straddle_data[i] = insts_i[i][15:0];
        if (i == 0 && carry) begin
          insts_o[i]   = asm_word;
          is_rvc_o[i]  = 1'b0;
          ptype_o[i]   = valid_o[i] ? asm_type : PREDECODE_NON_BRANCH;
          ptarget_o[i] = valid_o[i] ? asm_tgt : '0;
        end else begin
          insts_o[i]   = insts_i[i];
          is_rvc_o[i]  = is_rvc_i[i];
          ptype_o[i]   = valid_o[i] ? ptype_i[i] : PREDECODE_NON_BRANCH;
          ptarget_o[i] = valid_o[i] ? ptarget_i[i] : '0;
        end
      end
    end
    assign straddle = |straddle_oh;
    ttg_onehot_mux #(.N(FETCH_WIDTH), .W(XLEN_BITS)) u_complete_pc (.sel(complete_oh), .data(slot_pc), .out(complete_pc));
    assign seq_next_o = (|complete_oh) ? complete_pc + XLEN_BITS'(4) : seq_next_i;   // a completed instruction is 32 bits wide
    ttg_onehot_mux #(.N(FETCH_WIDTH), .W(16)) u_carry_low (.sel(straddle_oh), .data(straddle_data), .out(carry_low));
  end

endmodule

`default_nettype wire
