// Ref: front-end/BPU/type_predictor/TypePredictor.h  TypePredictor (hit/select/victim/update comb)
`default_nettype none

// One lane of the type predictor, purely combinational.  The lane has read the two ways of its set (entries are the
// START-of-cycle values).  Prediction: type of the first matching way, NONCTL on a miss.  Update: hit way, else first
// invalid way, else the way with the smaller age (way 0 on a tie); NONCTL clears a hit entry and ignores a miss;
// a same-type hit increments age (saturating), anything else restarts the entry with age=1.
// The C++ entry also has a 2-bit confidence counter; its only reader is the pred_confident output, which the BPU never
// looks at, so it is not stored.
module bpu_type_lane import bpu_pkg::*; (
  input  logic [TP_TAG_W-1:0] tag,
  input  tp_entry_t           way_entry [TP_WAYS],
  input  logic [2:0]          actual_type,
  output logic [2:0]          pred_type,
  output logic                upd_we,
  output logic [0:0]          upd_way,
  output tp_entry_t           upd_entry
);

  logic [TP_WAYS-1:0]  way_hit;
  logic                hit;
  logic [0:0]          hit_way;
  logic [0:0]          victim_way;
  logic [2:0]          old_type;                    // br_type / age of the hit entry
  logic [1:0]          old_age;
  logic                same_type_hit;

  always_comb begin
    for (int w = 0; w < TP_WAYS; w++) way_hit[w] = way_entry[w].valid && (way_entry[w].tag == tag);
    hit        = |way_hit;
    hit_way    = way_hit[0] ? 1'b0 : 1'b1;
    pred_type  = hit ? way_entry[hit_way].br_type : BR_NONCTL;
    // victim: first invalid way, else the smaller age (way 1 only if strictly smaller)
    victim_way = !way_entry[0].valid ? 1'b0 :
                 !way_entry[1].valid ? 1'b1 :
                 (way_entry[1].age < way_entry[0].age) ? 1'b1 : 1'b0;
  end

  always_comb begin
    upd_way       = hit ? hit_way : victim_way;
    old_type      = way_entry[hit_way].br_type;
    old_age       = way_entry[hit_way].age;
    same_type_hit = hit && (old_type == actual_type);
    upd_we        = (actual_type != BR_NONCTL) || hit;
    upd_entry.valid   = 1'b1;
    upd_entry.tag     = tag;
    upd_entry.br_type = actual_type;
    upd_entry.age     = same_type_hit ? ((old_age == 2'd3) ? 2'd3 : old_age + 2'd1) : 2'd1;
    if (actual_type == BR_NONCTL) upd_entry = '0;          // clear the hit entry
  end

endmodule

`default_nettype wire
