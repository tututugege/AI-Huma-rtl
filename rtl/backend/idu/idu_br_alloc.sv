// Ref: back-end/Idu.cpp  class Idu::comb_decode (alloc_tag[] / alloc_valid[] from tag_vec)
`default_nettype none

// Free-tag selector: the lowest NALLOC free tags, one one-hot vector per allocation slot k.
// Slot k holds the (k+1)-th lowest free tag, or all-zero when fewer than k+1 tags are free.
// Hardware form of "for i in tags: if free: alloc_tag[n++] = i": a chain of find-first-set stages,
// each stage removing the tag the previous stage took.
module idu_br_alloc #(
  parameter int NTAG   = 64,
  parameter int NALLOC = 8
) (
  input  logic [NTAG-1:0] tag_free,
  output logic [NTAG-1:0] alloc_oh [NALLOC]
);

  logic [NTAG-1:0] avail [NALLOC+1];

  assign avail[0] = tag_free;

  for (genvar k = 0; k < NALLOC; k++) begin : g_slot
    // isolate the lowest set bit of the remaining free tags (same function as ttg_first_set, without its unused `any`)
    assign alloc_oh[k] = avail[k] & (~avail[k] + NTAG'(1));
    assign avail[k+1] = avail[k] & ~alloc_oh[k];
  end

endmodule

`default_nettype wire
