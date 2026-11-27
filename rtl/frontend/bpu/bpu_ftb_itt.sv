// Ref: front-end/BPU/BpuFtb.h  struct BlockItt (Clean BPU v11: 3-table 2-Bank 1RW, Zero T0 Read)
`default_nettype none

module bpu_ftb_itt import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; import bpu_types_pkg::*; #(
  parameter int    N_ENT    = FTB_ITT_N,
  parameter int    NB       = BPU_ITT_BANKS,
  parameter bit    HOLD_RD0 = 1'b0,
  /* verilator lint_off UNUSEDPARAM */
  parameter [255:0] TAG     = "BPU_ITT"
  /* verilator lint_on UNUSEDPARAM */
) (
  input  logic                 clk,
  input  logic                 rst_n,
  // Predict sync read launch (write-wins rd_sup enforces conflict-free 2-Bank 1RW)
  input  logic                 rd_en,
  input  logic [NITT-1:0]      rd_sup,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t              rd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  output ftb_itt_raw_t         rd_raw,
  // Single-cycle pure commit write (computed from ftb_rec itt_meta_t; ZERO T0 read!)
  input  logic                 upd_en,
  /* verilator lint_off UNUSEDSIGNAL */
  input  ftb_ix_t              upd_ix,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [XLEN_BITS-1:0] upd_target,
  input  itt_meta_t            upd_meta,
  // Combinational write mask exported to bpu_ftb_arrays for write-wins arbitration
  output logic [NITT-1:0]      wr_mask_o
);

  localparam int IDX_W = $clog2(N_ENT);
  localparam int ENT_W = $bits(ftb_itt_ent_t);
  localparam int U_BIT = FTB_VA_BITS;

  logic [FTB_VA_BITS-1:0] upd_tgt38;
  assign upd_tgt38 = sv39_pack(upd_target);

  // ---- Pure-combinational commit plan from Meta ----
  logic [NITT-1:0] wr_mask, u_clr_only;
  ftb_itt_ent_t    wr_ent [NITT];

  always_comb begin
    logic         hit_found, correct, alloc_found, old_u, new_u;
    logic [1:0]   hit_k, start_k, alloc_k, old_conf, new_conf, conf_dec;
    logic [FTB_VA_BITS-1:0] new_tgt;

    wr_mask    = '0;
    u_clr_only = '0;
    for (int k = 0; k < NITT; k++) wr_ent[k] = '0;

    hit_found = upd_meta.hit;
    hit_k     = upd_meta.hit_k;
    correct   = hit_found && (upd_meta.target == upd_tgt38);

    old_conf = upd_meta.conf;
    old_u    = upd_meta.u_mask[hit_k];
    conf_dec = (old_conf > 2'd0) ? (old_conf - 2'd1) : 2'd0;
    new_tgt  = upd_meta.target;
    if (correct) begin
      new_conf = (old_conf < 2'd3) ? (old_conf + 2'd1) : 2'd3;
      new_u    = 1'b1;
    end else begin
      if (conf_dec == 2'd0) begin
        new_tgt  = upd_tgt38;
        new_conf = 2'd1;
      end else begin
        new_conf = conf_dec;
      end
      new_u = 1'b0;
    end

    start_k     = hit_found ? (hit_k + 2'd1) : 2'd0;
    alloc_found = 1'b0;
    alloc_k     = 2'd0;
    for (int k = 0; k < NITT; k++) begin
      if (!alloc_found && (2'(k) >= start_k) && (!upd_meta.valid_mask[k] || !upd_meta.u_mask[k])) begin
        alloc_found = 1'b1;
        alloc_k     = 2'(k);
      end
    end

    if (upd_en) begin
      if (hit_found && (!correct || (new_conf != old_conf) || (new_u != old_u))) begin
        wr_mask[hit_k] = 1'b1;
        wr_ent[hit_k]  = '{
          valid:  1'b1,
          tag:    upd_ix.tag[ITT_TBL[hit_k]],
          conf:   new_conf,
          u:      new_u,
          target: new_tgt
        };
      end
      if (!correct) begin
        if (alloc_found) begin
          wr_mask[alloc_k] = 1'b1;
          wr_ent[alloc_k]  = '{
            valid:  1'b1,
            tag:    upd_ix.tag[ITT_TBL[alloc_k]],
            conf:   2'd1,
            u:      1'b0,
            target: upd_tgt38
          };
        end else begin
          for (int k = 0; k < NITT; k++) begin
            if (2'(k) >= start_k) begin
              wr_mask[k]    = 1'b1;
              u_clr_only[k] = 1'b1;
              wr_ent[k]     = '0;
            end
          end
        end
      end
    end

    wr_mask_o = wr_mask;
  end

  // ---- 2-Bank 1RW SRAMs ----
  logic [ENT_W-1:0] rd0_raw [NITT];
  logic [NITT-1:0]  rd0_sup_q;

  always_ff @(posedge clk) begin
    if (!rst_n)      rd0_sup_q <= '0;
    else if (rd_en)  rd0_sup_q <= rd_sup;
  end

  for (genvar k = 0; k < NITT; k++) begin : g_tbl
    logic [ENT_W-1:0] bit_wm;
    assign bit_wm = u_clr_only[k] ? (ENT_W'(1) << U_BIT) : {ENT_W{1'b1}};

    bpu_sram_1rw_banked #(
      .W       (ENT_W),
      .DEPTH   (N_ENT),
      .NB      (NB),
      .MASK_W  (ENT_W),
      .HOLD_RD0(HOLD_RD0),
      .TAG     (TAG)
    ) u_mem (
      .clk         (clk),
      .rd0_en      (rd_en && !rd_sup[k]),
      .rd0_addr    (rd_ix.idx[ITT_TBL[k]][IDX_W-1:0]),
      .rd0_data    (rd0_raw[k]),
      .clr_rd_en   (1'b0),
      .clr_rd_addr ('0),
      /* verilator lint_off PINCONNECTEMPTY */
      .clr_rd_data (),
      /* verilator lint_on PINCONNECTEMPTY */
      .wr_en       (wr_mask[k]),
      .wr_addr     (upd_ix.idx[ITT_TBL[k]][IDX_W-1:0]),
      .wr_data     (ENT_W'(wr_ent[k])),
      .wr_wmask    (bit_wm),
      .rst_wr_en   (1'b0),
      .rst_wr_addr ('0),
      .rst_wr_data ('0),
      .rst_wr_wmask('0)
    );
    assign rd_raw[k] = rd0_sup_q[k] ? '0 : ftb_itt_ent_t'(rd0_raw[k]);
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  assign unused_ok = ^upd_target;
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
