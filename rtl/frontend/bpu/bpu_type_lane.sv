// Ref: front-end/BPU/type_predictor/TypePredictor.h  TypePredictor (hit/select/victim/update comb)
`default_nettype none

// One lane of the type predictor, purely combinational.  The lane has read the two ways of its set (entries are the
// START-of-cycle values).  Prediction: type of the first matching way, NONCTL on a miss.  Update: hit way, else first
// invalid way, else the way with the smaller age (way 0 on a tie); NONCTL clears a hit entry and ignores a miss;
// a same-type hit increments conf and age (saturating), anything else restarts the entry with conf=age=1.
module bpu_type_lane import bpu_pkg::*; (
  input  logic [TP_TAG_W-1:0] tag,
  input  logic [15:0]         way_entry [TP_WAYS],
  input  logic [2:0]          actual_type,
  output logic [2:0]          pred_type,
  output logic                upd_we,
  output logic [0:0]          upd_way,
  output logic [15:0]         upd_entry
);

  // entry layout: {valid, tag[7:0], type[2:0], conf[1:0], age[1:0]}
  logic [TP_WAYS-1:0]  way_hit;
  logic                hit;
  logic [0:0]          hit_way;
  logic [0:0]          victim_way;
  logic [6:0]          old_entry;                          // {type, conf, age} of the hit entry
  logic [1:0]          old_conf;
  logic [1:0]          old_age;
  logic [2:0]          old_type;
  logic                same_type_hit;

  always_comb begin
    for (int w = 0; w < TP_WAYS; w++) way_hit[w] = way_entry[w][15] && (way_entry[w][14:7] == tag);
    hit        = |way_hit;
    hit_way    = way_hit[0] ? 1'b0 : 1'b1;
    pred_type  = hit ? way_entry[hit_way][6:4] : BR_NONCTL;
    // victim: first invalid way, else the smaller age (way 1 only if strictly smaller)
    victim_way = !way_entry[0][15] ? 1'b0 :
                 !way_entry[1][15] ? 1'b1 :
                 (way_entry[1][1:0] < way_entry[0][1:0]) ? 1'b1 : 1'b0;
  end

  always_comb begin
    upd_way       = hit ? hit_way : victim_way;
    old_entry     = hit ? way_entry[hit_way][6:0] : 7'd0;
    old_type      = old_entry[6:4];
    old_conf      = old_entry[3:2];
    old_age       = old_entry[1:0];
    same_type_hit = hit && (old_type == actual_type);
    upd_we        = (actual_type != BR_NONCTL) || hit;
    if (actual_type == BR_NONCTL) begin
      upd_entry = 16'd0;                                   // clear the hit entry
    end else if (same_type_hit) begin
      upd_entry = {1'b1, tag, old_type, (old_conf == 2'd3) ? 2'd3 : old_conf + 2'd1,
                   (old_age == 2'd3) ? 2'd3 : old_age + 2'd1};
    end else begin
      upd_entry = {1'b1, tag, actual_type, 2'd1, 2'd1};
    end
  end

endmodule

`default_nettype wire
