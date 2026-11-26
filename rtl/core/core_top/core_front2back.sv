// Ref: Front2Back.cpp  Front2Back::comb (stall hold register only; no_taken cut moved to front_pred_path)
`default_nettype none

module core_front2back import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         can_read,
  // front.out (already no-taken cut in front_pred_path)
  input  logic [FETCH_WIDTH-1:0]       lane_valid,
  input  logic [31:0]                  instructions     [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0]       page_fault_inst,
  input  logic [FETCH_WIDTH-1:0]       pf_inst_hi,
  input  logic [FTQ_IDX_WIDTH-1:0]     ftq_idx,
  // back.in (ibuf instruction payload only; FTQ S0/S2/PD requests bypass directly)
  output logic [BACKEND_FETCH_WIDTH-1:0] back_valid,
  output logic [31:0]                  back_inst        [BACKEND_FETCH_WIDTH],
  output logic [BACKEND_FETCH_WIDTH-1:0] back_page_fault,
  output logic [BACKEND_FETCH_WIDTH-1:0] back_pf_inst_hi,
  output logic [FTQ_IDX_WIDTH-1:0]     back_ftq_idx
);

  localparam logic [31:0] INST_NOP_WORD = 32'h00000013;

  logic [BACKEND_FETCH_WIDTH-1:0] fe_valid;
  logic [31:0]                    fe_inst [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] fe_page_fault;
  logic [BACKEND_FETCH_WIDTH-1:0] fe_pf_inst_hi;

  always_comb begin
    for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
      fe_valid[j]      = 1'b0;
      fe_inst[j]       = INST_NOP_WORD;
      fe_page_fault[j] = 1'b0;
      fe_pf_inst_hi[j] = 1'b0;
    end
    for (int j = 0; j < FETCH_WIDTH; j++) begin
      fe_valid[j]      = lane_valid[j];
      fe_inst[j]       = instructions[j];
      fe_page_fault[j] = page_fault_inst[j];
      fe_pf_inst_hi[j] = pf_inst_hi[j];
    end
  end

  // Compact hold register (~566 FFs: valid/pf/pf_hi/inst/ftq_idx)
  logic [BACKEND_FETCH_WIDTH-1:0] hold_valid_q;
  logic [31:0]                    hold_inst_q [BACKEND_FETCH_WIDTH];
  logic [BACKEND_FETCH_WIDTH-1:0] hold_page_fault_q;
  logic [BACKEND_FETCH_WIDTH-1:0] hold_pf_inst_hi_q;
  logic [FTQ_IDX_WIDTH-1:0]       hold_ftq_idx_q;

  always_comb begin
    for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
      back_valid[j]      = can_read ? fe_valid[j]      : hold_valid_q[j];
      back_inst[j]       = can_read ? fe_inst[j]       : hold_inst_q[j];
      back_page_fault[j] = can_read ? fe_page_fault[j] : hold_page_fault_q[j];
      back_pf_inst_hi[j] = can_read ? fe_pf_inst_hi[j] : hold_pf_inst_hi_q[j];
    end
    back_ftq_idx = can_read ? ftq_idx : hold_ftq_idx_q;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
        hold_valid_q[j]      <= 1'b0;
        hold_inst_q[j]       <= INST_NOP_WORD;
        hold_page_fault_q[j] <= 1'b0;
        hold_pf_inst_hi_q[j] <= 1'b0;
      end
      hold_ftq_idx_q <= '0;
    end else begin
      for (int j = 0; j < BACKEND_FETCH_WIDTH; j++) begin
        hold_valid_q[j]      <= back_valid[j];
        hold_inst_q[j]       <= back_inst[j];
        hold_page_fault_q[j] <= back_page_fault[j];
        hold_pf_inst_hi_q[j] <= back_pf_inst_hi[j];
      end
      hold_ftq_idx_q <= back_ftq_idx;
    end
  end

endmodule

`default_nettype wire
