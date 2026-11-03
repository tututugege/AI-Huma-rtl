// Ref: back-end/Idu.cpp  class Idu (tag_vec, now_br_mask, comb_fire steps 0-4)
`default_nettype none

// Branch tag free-list and in-flight branch mask. Priority (same as the reference comb_fire):
//   ROB flush  >  mispredict recovery  >  normal commit of newly allocated tags.
// Resolved tags (clear_mask) are freed in every non-flush cycle before the above is applied.
module idu_br_state #(
  parameter int NTAG = 64
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            rob_flush,
  input  logic            latch_mispred,
  input  logic [NTAG-1:0] clear_mask,           // resolved tags, bit 0 already removed
  input  logic [NTAG-1:0] mispred_ckpt,         // checkpoint of the mispredicted branch (idu_br_cp read data)
  input  logic [NTAG-1:0] commit_all_oh,        // tags allocated this cycle
  output logic [NTAG-1:0] tag_free,             // tag_vec_q
  output logic [NTAG-1:0] now_br_mask           // now_br_mask_q
);

  localparam logic [NTAG-1:0] TAG0_MASK = NTAG'(1);   // tag 0 means "no branch": never free, never in the mask

  logic [NTAG-1:0] tag_free_q, tag_free_d;
  logic [NTAG-1:0] now_mask_q, now_mask_d;
  logic [NTAG-1:0] younger_tags;                // in flight now, not covered by the mispredicted branch's checkpoint
  logic [NTAG-1:0] free_after_clear, mask_after_clear;

  // Ref: Idu::comb_fire
  always_comb begin
    younger_tags     = now_mask_q & ~mispred_ckpt & ~TAG0_MASK;
    free_after_clear = tag_free_q | clear_mask;
    mask_after_clear = now_mask_q & ~clear_mask;
    if (rob_flush) begin
      tag_free_d = ~TAG0_MASK;
      now_mask_d = '0;
    end else if (latch_mispred) begin
      tag_free_d = free_after_clear | younger_tags;
      now_mask_d = mask_after_clear & ~younger_tags;
    end else begin
      tag_free_d = free_after_clear & ~commit_all_oh;
      now_mask_d = mask_after_clear | commit_all_oh;
    end
  end

  // Ref: Idu::seq ; reset = Idu::init (all tags free except tag 0, empty mask)
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tag_free_q <= ~TAG0_MASK;
      now_mask_q <= '0;
    end else begin
      tag_free_q <= tag_free_d;
      now_mask_q <= now_mask_d;
    end
  end

  assign tag_free    = tag_free_q;
  assign now_br_mask = now_mask_q;

endmodule

`default_nettype wire
