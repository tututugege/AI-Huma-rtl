// Ref: front-end/BPU/BPU_pipe.h  BpuPipe::ub_track (RVC=1: lane-serial form)
`default_nettype none

// RVC=1 form of bpu_ub_track: the same commit-order block tracker, written as the lane loop of the model.  With
// 16-bit instructions a sequential block end can lie inside an instruction (it straddles the end): the next block then
// starts at the block end, not at the next pc, and the following lane is still the continuation (tr_expect = next pc).
// The block start of the following lane therefore depends on the block end of the current one, which is why this
// form is serial over the lanes (the RVC=0 module resolves the lanes in parallel).
//
// Low-depth form (same events as the lane loop of the model, checked against it by random co-simulation).  The serial
// control state is kept as a small number instead of 64-bit addresses:
//   rem = bnd - expect    (how many bytes are left up to the block end bnd = block_bnd(start); <= 0: the end is reached),
// the full addresses only live in `expect` and `start` (registers tr_expect_q, tr_start_q).  The block start of a lane
// is then a select among lane-local values (pc, target, next pc, pc + k) controlled by the lane-loop outcomes.  Everything that compares addresses is computed
// from the lane inputs alone: "pc == expect" of lane i is a choice among equality tests of pc_i with the register and
// with the target / next pc of the earlier lanes (the expect of the last valid lane before i), and the block end of a
// new start is a function of its low address bits (rem_of).  What is left in the lane-to-lane loop are 8-bit values.
module bpu_ub_track_ser import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [NCOMMIT-1:0]  upd_valid,
  input  logic [XLEN_BITS-1:0]         base_pc  [NCOMMIT],
  input  logic [2:0]          br_type  [NCOMMIT],
  input  logic [NCOMMIT-1:0]  actual_dir,
  input  logic [NCOMMIT-1:0]  upd_is_rvc,
  input  logic [NCOMMIT-1:0]  pred_dir,
  input  logic [XLEN_BITS-1:0]         target   [NCOMMIT],
  output logic [NCOMMIT-1:0]  ev_valid,
  output ub_ev_t              ev       [NCOMMIT]
);

  localparam logic [1:0] EV_TAKEN = 2'd0;
  localparam logic [1:0] EV_FALL  = 2'd1;
  localparam logic [1:0] EV_NTSLOT = 2'd2;

  localparam int LB   = $clog2(ICACHE_LINE_SIZE);
  localparam int WB   = FETCH_WIDTH * SLOT_BYTES;       // block size
  typedef logic signed [7:0] num_t;

  // bytes from an address (given by its low LB bits) up to the end of its block: block_bnd(a) - a.  A table of the 2^LB
  // low-bit values (a constant), not arithmetic: the lookup is a few gate levels.
  function automatic num_t rem_calc(input int low);
    int plus_low;
    plus_low = low + WB;
    return (plus_low >> LB) != 0 ? num_t'(((plus_low >> LB) << LB) - low) : num_t'(WB);
  endfunction
  function automatic num_t rem_of(input logic [LB-1:0] low);
    num_t t [1 << LB];
    for (int a = 0; a < (1 << LB); a++) t[a] = rem_calc(a);
    return t[low];
  endfunction

  // rem as a one-hot vector (rem in -3 .. 32, bit rem + 3): the lane loop then only shifts and selects
  localparam int RN = 36;
  typedef logic [RN-1:0] rem_oh_t;
  function automatic rem_oh_t oh_of(input num_t r);
    rem_oh_t o;
    o = '0;
    for (int b = 0; b < RN; b++) if (int'(r) + 3 == b) o[b] = 1'b1;
    return o;
  endfunction

  logic                 tr_v_q, tr_v_d;
  logic [XLEN_BITS-1:0] tr_expect_q, tr_expect_d;
  logic [31:0]          tr_start_q, tr_start_d;
  rem_oh_t              tr_rem_q, tr_rem_d;   // remainder, one-hot
  logic                 tr_cond_q, tr_cond_d;   // a conditional branch was seen in the block (tr_nd > 0)

  // ---- lane-local values and address tests (inputs and the expect register only) ----
  logic [XLEN_BITS-1:0] nxt [NCOMMIT];
  logic [NCOMMIT-1:0]   taken, is_dir, ntslot;
  num_t                 len_l [NCOMMIT];
  num_t                 rem_pc [NCOMMIT], rem_tg [NCOMMIT], rem_nx [NCOMMIT];
  logic [NCOMMIT-1:0]   ne_exp;                    // pc_i != expect at lane i
  logic [XLEN_BITS-1:0] exp_last;                  // expect after the last valid lane
  always_comb begin
    for (int i = 0; i < NCOMMIT; i++) begin
      len_l[i] = upd_is_rvc[i] ? num_t'(2) : num_t'(4);
      nxt[i]   = base_pc[i] + (upd_is_rvc[i] ? XLEN_BITS'(2) : XLEN_BITS'(4));
      taken[i] = (br_type[i] != BR_NONCTL) && actual_dir[i];
      is_dir[i] = (br_type[i] == BR_DIRECT);
      ntslot[i] = !taken[i] && is_dir[i] && pred_dir[i];
      rem_pc[i] = rem_of(base_pc[i][LB-1:0]);
      rem_tg[i] = rem_of(target[i][LB-1:0]);
      rem_nx[i] = rem_of(nxt[i][LB-1:0]);
    end
    for (int i = 0; i < NCOMMIT; i++) begin
      logic ne;
      ne = base_pc[i] != tr_expect_q;
      for (int j = 0; j < i; j++) begin
        if (upd_valid[j]) ne = taken[j] ? (base_pc[i] != target[j]) : (base_pc[i] != nxt[j]);
      end
      ne_exp[i] = ne;
    end
    exp_last = tr_expect_q;
    for (int j = 0; j < NCOMMIT; j++) if (upd_valid[j]) exp_last = taken[j] ? target[j] : nxt[j];
  end

  // ---- per lane: the results of the "new block starts here" case, from the lane inputs alone ----
  logic [NCOMMIT-1:0] a_fall;
  rem_oh_t            a_rem [NCOMMIT];
  logic [NCOMMIT-1:0] a_cond;
  // the new block's remainder after a fall-through end at rem = k (k = 1 .. 4 <= len), and the block end pc + k
  rem_oh_t            rf_k [NCOMMIT][5];
  logic [31:0]        pc_k [NCOMMIT][5];
  always_comb begin
    for (int i = 0; i < NCOMMIT; i++) begin
      logic [LB-1:0] pl;
      pl = base_pc[i][LB-1:0];
      a_fall[i] = !taken[i] && !ntslot[i] && (rem_pc[i] <= len_l[i]);
      if (taken[i])           begin a_rem[i] = oh_of(rem_tg[i]); a_cond[i] = 1'b0; end
      else if (ntslot[i])     begin a_rem[i] = oh_of(rem_nx[i]); a_cond[i] = 1'b0; end
      else if (a_fall[i])     begin a_rem[i] = oh_of(rem_of(pl + LB'(rem_pc[i])) - (len_l[i] - rem_pc[i])); a_cond[i] = 1'b0; end
      else                    begin a_rem[i] = oh_of(rem_pc[i] - len_l[i]); a_cond[i] = is_dir[i]; end
      for (int k = 0; k <= 4; k++) begin
        rf_k[i][k] = oh_of(rem_of(pl + LB'(k)) - (len_l[i] - num_t'(k)));
        pc_k[i][k] = base_pc[i][31:0] + 32'(k);
      end
    end
  end

  // ---- the lane loop on the small control state (rem one-hot, cond, v) ----
  logic [NCOMMIT-1:0] nb_l, fall_l;       // per lane: a new block starts at the instruction / the block ends inside it
  logic [31:0]        fend_l [NCOMMIT];   // block end pc + rem of a fall-through end
  ub_ev_t             ev_b [NCOMMIT];     // events without the block start / slot
  always_comb begin
    logic                 v, cond, nb, fall_b, cond_b, sel_a;
    rem_oh_t              rem, rem_b, rem_fall, rem_plain;
    logic [31:0]          fe;
    v    = tr_v_q;
    rem  = tr_rem_q;
    cond = tr_cond_q;
    ev_valid = '0;
    nb_l = '0;
    fall_l = '0;
    for (int i = 0; i < NCOMMIT; i++) begin
      ev_b[i] = '0;
      fend_l[i] = '0;
      nb = 1'b0; cond_b = 1'b0; fall_b = 1'b0; sel_a = 1'b0;
      rem_b = '0; rem_fall = '0; rem_plain = '0; fe = '0;
      if (upd_valid[i]) begin
        nb     = !v || ne_exp[i] || (|rem[3:0]);                 // a new block starts at this instruction (rem <= 0)
        cond_b = cond || is_dir[i];
        // the block ends inside this instruction: rem in 1 .. len
        fall_b = !taken[i] && !ntslot[i] && (upd_is_rvc[i] ? (|rem[5:4]) : (|rem[7:4]));
        rem_fall = '0;
        fe = '0;
        for (int k = 1; k <= 4; k++) begin
          if (rem[3 + k]) begin rem_fall = rem_fall | rf_k[i][k]; fe = fe | pc_k[i][k]; end
        end
        rem_plain = upd_is_rvc[i] ? (rem >> 2) : (rem >> 4);
        sel_a  = nb || taken[i] || ntslot[i];
        rem_b  = fall_b ? rem_fall : rem_plain;
        nb_l[i]   = nb;
        fall_l[i] = nb ? a_fall[i] : fall_b;
        fend_l[i] = nb ? (base_pc[i][31:0] + 32'(rem_pc[i])) : fe;
        ev_b[i].ty = br_type[i];
        if (taken[i]) begin
          ev_valid[i] = 1'b1; ev_b[i].kind = EV_TAKEN; ev_b[i].tgt = target[i][XLEN_BITS-1:SLOT_SHIFT];
          ev_b[i].rvc = upd_is_rvc[i];
        end else if (ntslot[i]) begin
          ev_valid[i] = 1'b1; ev_b[i].kind = EV_NTSLOT;
        end else if (fall_l[i]) begin
          ev_valid[i] = nb ? is_dir[i] : cond_b; ev_b[i].kind = EV_FALL;
        end
        v = 1'b1;
        rem  = sel_a ? a_rem[i] : rem_b;
        cond = nb ? a_cond[i] : ((taken[i] || ntslot[i] || fall_b) ? 1'b0 : cond_b);
      end
    end
    tr_v_d      = v;
    tr_rem_d    = rem;
    tr_cond_d   = cond;
    tr_expect_d = exp_last;
  end

  // ---- block start of each lane: the value set last (new block at the pc, then a taken target / next pc / block end) ----
  logic [31:SLOT_SHIFT]  st_v [NCOMMIT];
  logic [UB_SLOT_W-1:0]  st_s [NCOMMIT];
  always_comb begin
    logic [31:0] cur;
    cur = tr_start_q;
    for (int i = 0; i < NCOMMIT; i++) begin
      st_v[i] = '0;
      st_s[i] = '0;
      if (upd_valid[i]) begin
        if (nb_l[i]) cur = base_pc[i][31:0];
        st_v[i] = cur[31:SLOT_SHIFT];
        st_s[i] = UB_SLOT_W'((base_pc[i][31:0] - cur) >> SLOT_SHIFT);
        if (taken[i])           cur = target[i][31:0];
        else if (ntslot[i])     cur = nxt[i][31:0];
        else if (fall_l[i])     cur = fend_l[i];
      end
    end
    tr_start_d = cur;
  end

  always_comb begin
    for (int i = 0; i < NCOMMIT; i++) begin
      ev[i] = ev_b[i];
      ev[i].start = st_v[i];
      ev[i].slot  = st_s[i];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tr_v_q      <= 1'b0;
      tr_expect_q <= '0;
      tr_start_q  <= '0;
      tr_rem_q    <= oh_of(8'sd0);
      tr_cond_q   <= 1'b0;
    end else begin
      tr_v_q      <= tr_v_d;
      tr_expect_q <= tr_expect_d;
      tr_start_q  <= tr_start_d;
      tr_rem_q    <= tr_rem_d;
      tr_cond_q   <= tr_cond_d;
    end
  end

endmodule

`default_nettype wire
