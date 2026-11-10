// Ref: front-end/BPU/target_predictor/BTB_top.h  BTB_TOP::btb_comb (update part), Btb::update (BTB way + ITT)
`default_nettype none

// Update decision of one BTB bank (one update per cycle, from the update queue).  Reads are done by the bank: this
// module gets the START-of-cycle contents and returns the write requests (all arrays are written at the clock edge).
//   BTB: taken control instructions write the hit way, else the victim (invalid, else smallest useful).
//   ITT: taken indirect jumps (idirect, icall) train the tables at the TAGE indices of their ITT_TBL: the provider (the
//        hit entry of the longest-history table) counts up on the same target, else counts down and is replaced at
//        confidence 0; unless the provider was right, the first longer table (all tables when there was no hit) whose
//        entry is invalid or not useful gets a new entry, and the useful bit of every longer entry passed on the way is
//        cleared.  With NITT = 1 this is the single-table rule.
module bpu_btb_upd import bpu_pkg::*; import bpu_btb_pkg::*; import bpu_stage_pkg::*; (
  input  logic                upd_valid,
  input  logic [31:0]         upd_pc,           // bank pc
  input  logic [31:0]         upd_actual_addr,
  input  logic [2:0]          upd_br_type,
  input  logic                upd_actual_dir,
  input  logic [NITT-1:0][T_TAG_W-1:0] upd_itt_tag,
  input  btb_ent_t            btb_set    [B_WAYS],     // set at btb_idx
  input  itt_ent_t [NITT-1:0] itt_old,                 // ITT entry of every table at its recorded index
  output logic [B_IDX_W-1:0]  btb_idx,
  output logic                btb_we,
  output logic [1:0]          btb_way,
  output btb_ent_t            btb_wdata,
  output logic [NITT-1:0]     itt_we,
  output itt_ent_t [NITT-1:0] itt_wdata
);

  logic                is_idirect_taken;
  logic                writes_btb;
  logic [B_TAG_W-1:0]  tag;
  logic [B_WAYS-1:0]   hit_way;
  logic                hit;
  logic [1:0]          hit_idx;
  logic [1:0]          victim;
  logic [1:0]          write_way;
  logic                correct_pred;
  logic [NITT-1:0]     itt_hit;
  int                  itt_prov;                    // provider table, -1 = no hit
  int                  itt_alloc_from;              // first table that may get a new entry
  logic                itt_alloc_done;
  logic                itt_en;

  // Ref: btb_comb, BTB way choice
  always_comb begin
    btb_idx          = btb_idx_of(upd_pc);
    tag              = btb_tag_of(upd_pc);
    is_idirect_taken = upd_actual_dir && (upd_br_type == BR_IDIRECT || upd_br_type == BR_ICALL);
    writes_btb       = (upd_br_type == BR_DIRECT) || (upd_br_type == BR_CALL) || (upd_br_type == BR_RET) ||
                       (upd_br_type == BR_JAL) || (upd_br_type == BR_IDIRECT) || (upd_br_type == BR_ICALL);
    for (int w = 0; w < B_WAYS; w++) hit_way[w] = btb_set[w].valid && (btb_set[w].tag == tag);
    hit     = |hit_way;
    hit_idx = hit_way[0] ? 2'd0 : hit_way[1] ? 2'd1 : hit_way[2] ? 2'd2 : 2'd3;
    // victim: first invalid way, else the way with the smallest useful (lowest index on ties)
    victim = 2'd0;
    for (int w = B_WAYS - 1; w >= 0; w--) if (btb_set[w].useful <= btb_set[victim].useful) victim = 2'(w);
    for (int w = B_WAYS - 1; w >= 0; w--) if (!btb_set[w].valid) victim = 2'(w);
    write_way    = hit ? hit_idx : victim;
    correct_pred = hit && (btb_set[write_way].bta == upd_actual_addr);
  end

  always_comb begin
    btb_we  = upd_valid && upd_actual_dir && writes_btb;
    btb_way = write_way;
    btb_wdata.valid  = 1'b1;
    btb_wdata.tag    = tag;
    btb_wdata.bta    = upd_actual_addr;
    btb_wdata.useful = (upd_br_type == BR_IDIRECT || upd_br_type == BR_ICALL) ? 3'd0 :
                       hit ? useful_next_of(btb_set[write_way].useful, correct_pred) : 3'd1;
  end

  // Ref: Btb::update, ITT
  always_comb begin
    itt_en = upd_valid && is_idirect_taken;
    for (int k = 0; k < NITT; k++) itt_hit[k] = itt_old[k].valid && (itt_old[k].tag == upd_itt_tag[k]);
    itt_prov = -1;
    for (int k = 0; k < NITT; k++) if (itt_hit[k]) itt_prov = k;        // the longest-history hit provides
    itt_we         = '0;
    itt_wdata      = itt_old;
    itt_alloc_from = 0;
    for (int k = 0; k < NITT; k++) begin
      if (k == itt_prov) begin
        itt_we[k] = itt_en;
        if (itt_old[k].target == upd_actual_addr) begin
          itt_wdata[k].conf   = (itt_old[k].conf == 2'd3) ? 2'd3 : itt_old[k].conf + 2'd1;
          itt_wdata[k].useful = 1'b1;
          itt_alloc_from      = NITT;
        end else begin
          if (itt_old[k].conf != 2'd0) itt_wdata[k].conf = itt_old[k].conf - 2'd1;
          else                         itt_wdata[k].target = upd_actual_addr;
          itt_wdata[k].useful = 1'b0;
          itt_alloc_from      = k + 1;
        end
      end
    end
    itt_alloc_done = 1'b0;
    for (int k = 0; k < NITT; k++) begin
      if (k >= itt_alloc_from && !itt_alloc_done) begin
        itt_we[k] = itt_en;
        if (!itt_old[k].valid || !itt_old[k].useful) begin
          itt_wdata[k].valid  = 1'b1;
          itt_wdata[k].tag    = upd_itt_tag[k];
          itt_wdata[k].conf   = 2'd0;
          itt_wdata[k].useful = 1'b0;
          itt_wdata[k].target = upd_actual_addr;
          itt_alloc_done      = 1'b1;
        end else begin
          itt_wdata[k].useful = 1'b0;
        end
      end
    end
  end

endmodule

`default_nettype wire
