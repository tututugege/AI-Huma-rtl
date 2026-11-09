// Ref: back-end/Lsu/RealLsuPipe.cpp  wb_insert (one store of the batch)
`default_nettype none

// One step of the write-buffer insertion: the next committed store is skipped (MMIO / suppressed), merged into the
// youngest entry (still waiting and not sent in this cycle) or starts a new entry in a free slot; a full buffer stops
// the batch.
module lp_wbstep
  import lp_pkg::*;
(
  input  wbs_t            ent_i,
  input  ltm_t            lt_i,
  input  wbb_t            b_i,
  output wbs_t            ent_o,
  output ltm_t            lt_o,
  output wbb_t            b_o,
  input  logic [NWB-1:0]  v_reg,         // registered occupancy
  input  logic [NWB-1:0]  st_reg,        // registered "sent"
  input  logic [NWB-1:0]  issue,         // entries sent in this cycle
  input  logic            pick_v,
  input  logic [SQW-1:0]  jk,
  input  wbi_t            s,
  output logic            mark
);

  always_comb begin
    logic merge_ok, have_free;
    merge_ok = 1'b0;
    have_free = 1'b0;
    ent_o = ent_i;
    lt_o = lt_i;
    b_o = b_i;
    mark = 1'b0;
    if (b_i.go && pick_v) begin
      if (s.mmio || s.done) begin
        mark = 1'b1;
      end else begin
        merge_ok = b_i.tail_v && !s.lrsc && b_i.t_mg && !b_i.t_two && b_i.t_line == s.paddr[31:6] &&
                   (b_i.tail_new || (!st_reg[b_i.tail] && !issue[b_i.tail]));
        if (merge_ok) begin
          ent_o[b_i.tail].two = 1'b1;
          ent_o[b_i.tail].m1 = jk;
          ent_o[b_i.tail].a1 = s.paddr;
          ent_o[b_i.tail].d1 = s.data;
          ent_o[b_i.tail].f1 = s.f3;
          b_o.t_two = 1'b1;
          mark = 1'b1;
        end else begin
          have_free = 1'b0;
          for (int e = NWB - 1; e >= 0; e--) if (!v_reg[e] && !b_i.alloc[e]) begin
            have_free = 1'b1;
            b_o.tail = 2'(e);
          end
          if (!have_free) begin
            b_o.go = 1'b0;
          end else begin
            b_o.alloc[b_o.tail] = 1'b1;
            ent_o[b_o.tail].v = 1'b1;
            ent_o[b_o.tail].st = 1'b0;
            ent_o[b_o.tail].mg = !s.lrsc;
            ent_o[b_o.tail].two = 1'b0;
            ent_o[b_o.tail].line = s.paddr[31:6];
            ent_o[b_o.tail].m0 = jk;
            ent_o[b_o.tail].a0 = s.paddr;
            ent_o[b_o.tail].d0 = s.data;
            ent_o[b_o.tail].f0 = s.f3;
            for (int o = 0; o < NWB; o++) begin
              lt_o[o][b_o.tail] = v_reg[o] || b_i.alloc[o];
              lt_o[b_o.tail][o] = 1'b0;
            end
            b_o.tail_v = 1'b1;
            b_o.tail_new = 1'b1;
            b_o.t_mg = !s.lrsc;
            b_o.t_two = 1'b0;
            b_o.t_line = s.paddr[31:6];
            mark = 1'b1;
          end
        end
      end
    end
  end

endmodule

`default_nettype wire
