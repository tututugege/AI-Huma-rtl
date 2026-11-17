// the lane-to-lane state of the old serial tlb_mmu_core (reference copy for the equivalence test only)
package tlb_ref_pkg;
  import tlb_mmu_pkg::*;
  // state handed from one lane to the next (top_comb shadow_*): the walk, the refill of this cycle, and whether the PTW
  // response is still unconsumed (the request slot needs no shadow: once a port has sent a request the walk is active
  // with req_sent set and the response is hidden, so no later port can start a second request)
  typedef struct packed {
    tlb_mmu_walk_t  walk;
    logic           refill_valid;
    tlb_mmu_entry_t refill;
    logic           resp_valid;
  } tlb_mmu_chain_t;

endpackage
