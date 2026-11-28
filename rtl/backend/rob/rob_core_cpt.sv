// Ref: back-end/Rob.cpp  class Rob (compact ROB, EXP-028): comb_ready, comb_ftq_pc_req, comb_commit_compact,
//      comb_branch, comb_fire, comb_flush, seq
`default_nettype none

// Compact ROB (EXP-028).  Entries are allocated one after another: rob_idx is the ring position, entry e lives in
// bank e % 8, line e / 8 (the same storage as the line ROB); a dispatch group no longer takes a whole line.
// State: head entry, number of valid entries, wrap flag of the head.  The 8 oldest entries form the commit window:
// bank b holds window slot (b - head) mod 8 in line head_line or head_line + 1, rotated to the slot order.
// Commit: the head retires alone when it is a flush-type / fence / WFI instruction (or an interrupt is taken);
// otherwise the longest completed prefix of the window that holds no such instruction, cut by the BPU commit
// credits: the control-flow instructions may not exceed the free update-queue entries and the fetch-block ends may
// not exceed the free uBTB train-queue entries, both from the registered BPU occupancy minus what was committed
// last cycle (those commits reach the BPU queues this cycle).  The oldest entry is never held back by the credits.
// A mispredict keeps the entries up to the branch (the tail moves to the entry after it).
module rob_core_cpt
  import ttg_cfg_pkg::*;
  import rob_pkg::*;
(
  input  logic                       clk,
  input  logic                       rst_n,
  // inputs
  input  logic                       dec_mispred,
  input  logic                       ren_walking,      // Ren forward walk in progress (1R1W RenLog: pause commit)
  input  logic [ROB_IDX_WIDTH-1:0]   dec_redirect_rob_idx,
  input  logic                       interrupt_req,
  input  logic                       committed_store_pending,
  input  logic                       front_stall,
  input  logic [3:0]                 bpu_upd_free,     // BPU update queue: free entries at the start of the cycle
  input  logic [3:0]                 bpu_tq_free,      // uBTB train queue: free entries at the start of the cycle
  input  logic [FTQ_IDX_WIDTH-1:0]   ftq_head,         // oldest live FTQ index (8-bank commit window guard)
  input  logic [ROB_XLEN-1:0]            ftq_resp_pc,
  input  logic [ROB_BANK_NUM-1:0]    dis_fire,
  input  logic [ROB_IDX_WIDTH-1:0]   dis_rob_idx [ROB_BANK_NUM],
  input  logic [ROB_XLEN-1:0]        dis_trap_val [ROB_BANK_NUM],
  input  logic                       csr_fs_off,
  input  rob_entry_t                 dis_uop [ROB_BANK_NUM],
  input  rob_wb_t                    wb [ROB_WB_WIDTH],
  // rob2dis
  output logic                       rob2dis_stall,
  output logic                       rob2dis_empty,
  output logic                       rob2dis_ready,
  output logic [ROB_IDX_WIDTH-1:0]   rob2dis_enq_idx,  // tail entry (the first dispatched instruction goes here)
  output logic                       rob2dis_rob_flag,
  output logic [ROB_IDX_WIDTH:0]     rob2dis_free,     // free entries
  // rob2csr
  output logic                       rob2csr_commit,
  output logic                       rob2csr_interrupt_resp,
  // rob_commit (slot k = k-th oldest entry)
  output logic [ROB_BANK_NUM-1:0]    commit_valid,
  output logic [ROB_IDX_WIDTH-1:0]   commit_rob_idx [ROB_BANK_NUM],
  output rob_entry_t                 commit_uop [ROB_BANK_NUM],
  // rob_bcast
  output logic                       bcast_flush,
  output logic                       bcast_mret,
  output logic                       bcast_sret,
  output logic                       bcast_ecall,
  output logic                       bcast_breakpoint,
  output logic                       bcast_exception,
  output logic                       bcast_fence,
  output logic                       bcast_fence_i,
  output logic                       bcast_page_fault_inst,
  output logic                       bcast_page_fault_load,
  output logic                       bcast_page_fault_store,
  output logic                       bcast_illegal_inst,
  output logic                       bcast_interrupt,
  output logic                       bcast_trap_val_valid,
  output logic [ROB_XLEN-1:0]            bcast_trap_val,
  output logic [ROB_XLEN-1:0]            bcast_pc,
  output logic [ROB_IDX_WIDTH-1:0]   bcast_head_rob_idx,
  output logic                       bcast_head_valid,
  output logic [ROB_IDX_WIDTH-1:0]   bcast_head_incomplete_rob_idx,
  output logic                       bcast_head_incomplete_valid,
  // ftq_pc_req
  output logic                       ftq_req_valid,
  output logic [FTQ_IDX_WIDTH-1:0]   ftq_req_ftq_idx,
  output logic [FTQ_OFFSET_WIDTH-1:0] ftq_req_ftq_offset
);

  localparam int NB    = ROB_BANK_NUM;
  localparam int NL    = ROB_LINE_NUM;
  localparam int IW    = ROB_IDX_WIDTH;
  localparam int BW    = ROB_BANK_IDX_W;
  localparam int LW    = ROB_LINE_IDX_W;
  localparam int SLOTW = 1 + ROB_ENTRY_W;
  localparam int CW    = $clog2(NB + 1);   // 0 .. 8

  // ---- state ----
  logic [IW-1:0] head_q;
  logic          hflag_q;
  logic [IW:0]   count_q;
  logic [CW-1:0] prev_ctl_q, prev_blk_q;   // control-flow instructions / fetch-block ends committed last cycle
  // registered views of the head (kept in step with head_q, so the read does not decode the pointer every cycle)
  logic [NL-1:0] head_oh_q;    // one-hot head line
  logic [NB-1:0] use_next_q;   // bank b reads the line after the head line (b < head bank)
  logic [NB-1:0] hb_oh_q;      // one-hot head bank
  // unified oldest-trap tval register (pf_load / pf_store vaddr or illegal instruction word)
  logic                trap_v_q, trap_v_d;
  logic [IW-1:0]       trap_idx_q, trap_idx_d;
  logic [ROB_XLEN-1:0] trap_val_q, trap_val_d;
  // next state
  logic [IW-1:0] head_d;
  logic          hflag_d;
  logic [IW:0]   count_d;

  // ---- storage ----
  logic       slot_valid [NB][NL];
  rob_entry_t slot_uop   [NB][NL];
  logic [SLOTW-1:0] slot_bits [NB][NL];

  // ---- per-bank views ----
  logic [NL-1:0]   next_oh;                 // one-hot line after the head line
  logic [NL-1:0]   rd_onehot [NB];          // line of bank b that holds a window slot
  logic [NB-1:0]   slot_sel  [NB];          // slot_sel[k][b]: window slot k is in bank b ((head + k) mod 8)
  logic [NB-1:0]   bank_clr;                // the window slot held by bank b retires this cycle
  logic [SLOTW-1:0] bank_bits [NB];
  // ---- commit window (slot order) ----
  logic [NB-1:0]   w_valid, w_in, w_complete, w_flush, w_fence, w_wfi, w_ctl, w_last;
  rob_entry_t      w_uop [NB];
  logic [SLOTW-1:0] w_bits [NB];
  // ---- decisions ----
  logic          nonempty, mispred_any, recover, flush_w;
  logic          h_alone, single_commit, interrupt_fire, group_go;
  logic [NB-1:0] ok, prefix;
  logic [CW-1:0] m_fire, ctl_c, blk_c;
  logic signed [5:0] upd_free, tq_free;
  // ---- enqueue ----
  logic [NB-1:0]   bank_we;
  rob_entry_t      bank_uop  [NB];
  logic [LW-1:0]   bank_line [NB];
  // ---- branch recovery ----
  logic [IW-1:0]   br_off;
  logic [IW:0]     keep;
  // ---- write-back events ----
  rob_event_t      wb_ev [ROB_WB_WIDTH];

  rob_wb_decode u_wb_decode (.wb(wb), .wb_ev(wb_ev));

  assign nonempty    = count_q != '0;
  assign mispred_any = dec_mispred;
  assign recover     = dec_mispred && !flush_w;
  // ---- read: bank b holds window slot (b - head) mod 8, in the head line or the next one ----
  assign next_oh = {head_oh_q[NL-2:0], head_oh_q[NL-1]};
  for (genvar b = 0; b < NB; b++) begin : g_rd
    assign rd_onehot[b] = use_next_q[b] ? next_oh : head_oh_q;
    ttg_onehot_mux #(.N(NL), .W(SLOTW)) u_rd_mux (.sel(rd_onehot[b]), .data(slot_bits[b]), .out(bank_bits[b]));
  end

  // rotate banks to window slots: slot k is bank (head + k) mod 8, i.e. bank b when the head bank is (b - k) mod 8
  for (genvar k = 0; k < NB; k++) begin : g_rot
    for (genvar b = 0; b < NB; b++) begin : g_sel
      assign slot_sel[k][b] = hb_oh_q[(b - k + NB) % NB];
    end
    ttg_onehot_mux #(.N(NB), .W(SLOTW)) u_rot (.sel(slot_sel[k]), .data(bank_bits), .out(w_bits[k]));
  end
  always_comb begin
    for (int b = 0; b < NB; b++) begin
      bank_clr[b] = 1'b0;
      for (int k = 0; k < NB; k++) bank_clr[b] = bank_clr[b] | (slot_sel[k][b] & commit_valid[k]);
    end
  end

  for (genvar k = 0; k < NB; k++) begin : g_win
    assign w_valid[k]    = w_bits[k][ROB_ENTRY_W];
    assign w_uop[k]      = w_bits[k][ROB_ENTRY_W-1:0];
    assign w_in[k]       = count_q > (IW+1)'(k);        // the slot holds a valid entry
    assign w_complete[k] = rob_is_complete(w_uop[k]);
    assign w_flush[k]    = rob_is_flush_inst(w_uop[k]);
    assign w_fence[k]    = rob_is_fence_inst(w_uop[k]);
    assign w_wfi[k]      = rob_is_wfi(w_uop[k]);
    assign w_ctl[k]      = (w_uop[k].itype == ITYPE_BR) | (w_uop[k].itype == ITYPE_JAL) |
                           (w_uop[k].itype == ITYPE_JALR);
    assign w_last[k]         = w_uop[k].ftq_is_last;
    assign commit_rob_idx[k] = head_q + IW'(k);
    assign commit_uop[k]     = w_uop[k];
  end

  // ---- commit (Rob::comb_commit_compact) ----
  always_comb begin
    logic [CW-1:0] ctl_before, blk_before;
    upd_free = $signed({2'b0, bpu_upd_free}) - $signed({2'b0, prev_ctl_q});
    tq_free  = $signed({2'b0, bpu_tq_free}) - $signed({2'b0, prev_blk_q});
    h_alone = w_flush[0] | w_fence[0] | w_wfi[0];
    interrupt_fire = !mispred_any && !ren_walking && nonempty && interrupt_req;
    single_commit  = interrupt_fire ||
                     (!mispred_any && !ren_walking && nonempty && !interrupt_req && h_alone && w_complete[0] &&
                      !(w_fence[0] && committed_store_pending));
    group_go = !mispred_any && !ren_walking && nonempty && !interrupt_req && !h_alone;
    // every slot counts the older control-flow instructions / block ends on its own (parallel, no running sum)
    for (int k = 0; k < NB; k++) begin
      ctl_before = '0;
      blk_before = '0;
      for (int j = 0; j < k; j++) begin
        ctl_before = ctl_before + CW'(w_ctl[j]);
        blk_before = blk_before + CW'(w_last[j]);
      end
      ok[k] = w_in[k] && w_complete[k] && !w_flush[k] && !w_fence[k] && !w_wfi[k] && !(front_stall && k > 0);
      if (k > 0) begin
        /* verilator lint_off UNUSEDSIGNAL */
        logic [FTQ_IDX_WIDTH-1:0] ftq_diff;
        /* verilator lint_on UNUSEDSIGNAL */
        ftq_diff = w_uop[k].ftq_idx - ftq_head;
        if (|ftq_diff[FTQ_IDX_WIDTH-1:3]) ok[k] = 1'b0;
        if (w_ctl[k] && $signed({2'b0, ctl_before}) >= upd_free) ok[k] = 1'b0;
        if (w_last[k] && $signed({2'b0, blk_before}) >= tq_free) ok[k] = 1'b0;
      end
    end
    for (int k = 0; k < NB; k++) prefix[k] = &(ok | ~(NB'((1 << (k + 1)) - 1)));
    commit_valid = single_commit ? NB'(1) : (group_go ? prefix : '0);
    ctl_c = '0;
    blk_c = '0;
    for (int k = 0; k < NB; k++) begin
      ctl_c = ctl_c + CW'(commit_valid[k] & w_ctl[k]);
      blk_c = blk_c + CW'(commit_valid[k] & w_last[k]);
    end
  end

  // ---- head information (Rob::comb_ready / comb_ftq_pc_req / comb_commit_compact) ----
  always_comb begin
    logic found;
    rob2dis_stall = |(w_in & w_flush);
    ftq_req_valid = nonempty;
    ftq_req_ftq_idx = w_uop[0].ftq_idx;
    ftq_req_ftq_offset = w_uop[0].ftq_offset;
    bcast_head_valid = nonempty;
    bcast_head_rob_idx = nonempty ? head_q : '0;
    bcast_head_incomplete_valid = 1'b0;
    bcast_head_incomplete_rob_idx = '0;
    found = 1'b0;
    for (int k = 0; k < NB; k++) begin
      if (!found && w_in[k] && !w_complete[k]) begin
        found = 1'b1;
        bcast_head_incomplete_valid = 1'b1;
        bcast_head_incomplete_rob_idx = head_q + IW'(k);
      end
    end
  end

  // ---- dispatch side (Rob::comb_commit_compact tail, comb_ready) ----
  logic [IW:0] tail_sum;
  assign tail_sum         = {1'b0, head_q} + count_q;
  assign rob2dis_enq_idx  = tail_sum[IW-1:0];
  assign rob2dis_rob_flag = hflag_q ^ tail_sum[IW];
  assign rob2dis_free     = (IW+1)'(ROB_NUM) - count_q;
  assign rob2dis_empty    = !nonempty;
  assign rob2dis_ready    = count_q != (IW+1)'(ROB_NUM);

  // ---- enqueue (Rob::comb_fire): Dispatch numbered the fired slots tail, tail+1, ...; bank b takes the slot
  // whose rob_idx falls in it (at most one: at most 8 consecutive entries) ----
  logic [31:0] bank_inst_word [NB];
  logic [31:0] bank_inst_rd   [NB];
  logic [31:0] head_inst_word;

  always_comb begin
    m_fire = '0;
    for (int i = 0; i < NB; i++) m_fire = m_fire + CW'(dis_fire[i] & rob2dis_ready);
    for (int b = 0; b < NB; b++) begin
      bank_we[b]        = 1'b0;
      bank_uop[b]       = '0;
      bank_line[b]      = '0;
      bank_inst_word[b] = '0;
      for (int i = 0; i < NB; i++) begin
        if (dis_fire[i] && rob2dis_ready && dis_rob_idx[i][BW-1:0] == BW'(b)) begin
          bank_we[b]        = 1'b1;
          bank_uop[b]       = dis_uop[i];
          bank_line[b]      = dis_rob_idx[i][IW-1:BW];
          bank_inst_word[b] = dis_trap_val[i][31:0];
        end
      end
    end
  end

  // 8 x (32 x 32b) strict sync 1R1W SRAM storing 32-bit instruction words for illegal-instruction mtval
  // (covers decode-time, FS=Off, and execute-time FP illegal exceptions with 0 ROB entry FF overhead).
  for (genvar b = 0; b < NB; b++) begin : g_inst_sram
    ttg_sram_1r1w #(
      .DEPTH      (NL),
      .WIDTH      (32),
      .MASK_W     (1),
      .WRITE_FIRST(1'b1),
      .TAG        ("ROB_INST_WORD")
    ) u_inst_sram (
      .clk  (clk),
      .re   (head_d[BW-1:0] == BW'(b)),
      .raddr(head_d[IW-1:BW]),
      .rdata(bank_inst_rd[b]),
      .we   (bank_we[b]),
      .waddr(bank_line[b]),
      .wdata(bank_inst_word[b]),
      .wmask(1'b1)
    );
  end
  assign head_inst_word = bank_inst_rd[head_q[BW-1:0]];

  // ---- branch recovery (Rob::comb_branch): keep the entries up to the branch ----
  assign br_off = dec_redirect_rob_idx - head_q;
  assign keep   = {1'b0, br_off} + (IW+1)'(1);

  // ---- storage ----
  for (genvar b = 0; b < NB; b++) begin : g_bank
    for (genvar l = 0; l < NL; l++) begin : g_line
      localparam int E = l * NB + b;
      logic [IW-1:0] off;
      logic          clr_commit, clr_branch, mark;
      assign off        = IW'(E) - head_q;
      // committed: window slot (b - head) mod 8 of the line that bank b reads
      assign clr_commit = bank_clr[b] && rd_onehot[b][l];
      assign clr_branch = recover && off > br_off;
      assign mark       = recover && dec_redirect_rob_idx == IW'(E);
      rob_entry #(.ENTRY_IDX(E)) u_entry (
        .clk(clk), .rst_n(rst_n), .flush(flush_w),
        .fire_we(bank_we[b] && bank_line[b] == LW'(l)), .fire_uop(bank_uop[b]),
        .commit_clr(clr_commit), .branch_clr(clr_branch), .mark_last(mark),
        .wb_ev(wb_ev), .entry_valid(slot_valid[b][l]), .entry_uop(slot_uop[b][l])
      );
      assign slot_bits[b][l] = {slot_valid[b][l], slot_uop[b][l]};
    end
  end

  // ---- oldest pf_load / pf_store faulting-vaddr tracker (3-level binary tournament over cur + 7 LSU ports) ----
  typedef struct packed {
    logic                v;
    logic [IW-1:0]       off;
    logic [IW-1:0]       idx;
    logic [ROB_XLEN-1:0] val;
  } trap_cand_t;

  function automatic trap_cand_t pick_older_trap(input trap_cand_t a, input trap_cand_t b);
    if (!a.v)                return b;
    else if (!b.v)           return a;
    else if (b.off <= a.off) return b; // higher port (STA > LD > cur) wins ties (e.g. AMO pf_store over pf_load)
    else                     return a;
  endfunction

  always_comb begin
    trap_cand_t c0 [8];
    trap_cand_t c1 [4];
    trap_cand_t c2 [2];
    /* verilator lint_off UNUSEDSIGNAL */
    trap_cand_t win;
    /* verilator lint_on UNUSEDSIGNAL */

    for (int k = 0; k < 8; k++) c0[k] = '0;
    c0[0].v   = trap_v_q && !(recover && ((trap_idx_q - head_q) > br_off));
    c0[0].off = trap_idx_q - head_q;
    c0[0].idx = trap_idx_q;
    c0[0].val = trap_val_q;

    for (int k = 0; k < LSU_LOAD_WB_WIDTH; k++) begin
      logic [IW-1:0] off_p;
      off_p = wb_ev[ROB_WB_LD_BASE + k].rob_idx - head_q;
      c0[1 + k].v   = wb_ev[ROB_WB_LD_BASE + k].valid &&
                      (wb_ev[ROB_WB_LD_BASE + k].pf_load || wb_ev[ROB_WB_LD_BASE + k].pf_store) &&
                      (!recover || (off_p <= br_off));
      c0[1 + k].off = off_p;
      c0[1 + k].idx = wb_ev[ROB_WB_LD_BASE + k].rob_idx;
      c0[1 + k].val = wb[ROB_WB_LD_BASE + k].result;
    end
    for (int k = 0; k < LSU_STA_COUNT; k++) begin
      logic [IW-1:0] off_p;
      off_p = wb_ev[ROB_WB_STA_BASE + k].rob_idx - head_q;
      c0[1 + LSU_LOAD_WB_WIDTH + k].v   = wb_ev[ROB_WB_STA_BASE + k].valid &&
                                          (wb_ev[ROB_WB_STA_BASE + k].pf_load || wb_ev[ROB_WB_STA_BASE + k].pf_store) &&
                                          (!recover || (off_p <= br_off));
      c0[1 + LSU_LOAD_WB_WIDTH + k].off = off_p;
      c0[1 + LSU_LOAD_WB_WIDTH + k].idx = wb_ev[ROB_WB_STA_BASE + k].rob_idx;
      c0[1 + LSU_LOAD_WB_WIDTH + k].val = wb[ROB_WB_STA_BASE + k].result;
    end

    for (int k = 0; k < 4; k++) c1[k] = pick_older_trap(c0[2*k], c0[2*k + 1]);
    for (int k = 0; k < 2; k++) c2[k] = pick_older_trap(c1[2*k], c1[2*k + 1]);
    win = pick_older_trap(c2[0], c2[1]);

    if (flush_w) begin
      trap_v_d   = 1'b0;
      trap_idx_d = '0;
      trap_val_d = '0;
    end else begin
      trap_v_d   = win.v;
      trap_idx_d = win.idx;
      trap_val_d = win.val;
    end
  end

  // ---- trap / flush of the single-retired head ----
  rob_trap_ctrl u_trap (
    .single_commit(single_commit), .interrupt_fire(interrupt_fire),
    .single_uop(w_uop[0]), .ftq_resp_pc(ftq_resp_pc),
    .oldest_trap_val((trap_v_q && (trap_idx_q == head_q)) ? trap_val_q : '0),
    .head_inst_word(head_inst_word),
    .flush(flush_w), .exception(bcast_exception), .mret(bcast_mret), .sret(bcast_sret), .ecall(bcast_ecall),
    .fence(bcast_fence), .fence_i(bcast_fence_i),
    .page_fault_inst(bcast_page_fault_inst), .page_fault_load(bcast_page_fault_load),
    .page_fault_store(bcast_page_fault_store), .illegal_inst(bcast_illegal_inst), .breakpoint(bcast_breakpoint),
    .rob2csr_commit(rob2csr_commit), .trap_val_valid(bcast_trap_val_valid), .trap_val(bcast_trap_val), .pc(bcast_pc)
  );
  assign bcast_flush            = flush_w;
  assign bcast_interrupt        = interrupt_fire;
  assign rob2csr_interrupt_resp = interrupt_fire;

  // ---- next state (Rob::seq): flush > recovery > commit + enqueue.  commit_valid is a thermometer (a prefix), so the
  // committed count is selected among head + j / count - j precomputed from the registers, not added up ----
  always_comb begin
    logic [NB:0]   n_oh;                     // one-hot number of committed entries (0 .. 8)
    logic [IW:0]   head_sel, cnt_sel;
    n_oh[0] = !commit_valid[0];
    for (int j = 1; j < NB; j++) n_oh[j] = commit_valid[j-1] & !commit_valid[j];
    n_oh[NB] = commit_valid[NB-1];
    head_sel = '0;
    cnt_sel  = '0;
    for (int j = 0; j <= NB; j++) begin
      if (n_oh[j]) begin
        head_sel = {hflag_q, head_q} + (IW+1)'(j);   // the flag flips when the head wraps
        cnt_sel  = count_q - (IW+1)'(j);
      end
    end
    if (flush_w) begin
      {hflag_d, head_d} = '0;
      count_d = '0;
    end else begin
      {hflag_d, head_d} = head_sel;
      count_d = (recover ? keep : cnt_sel) + (IW+1)'(m_fire);
    end
  end

  // bank b reads the next line when the head bank is above b
  logic [NB-1:0] use_next_d;
  always_comb begin
    for (int b = 0; b < NB; b++) begin
      use_next_d[b] = 1'b0;
      for (int h = b + 1; h < NB; h++) use_next_d[b] = use_next_d[b] | (head_d[BW-1:0] == BW'(h));
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      head_q     <= '0;
      hflag_q    <= 1'b0;
      count_q    <= '0;
      prev_ctl_q <= '0;
      prev_blk_q <= '0;
      head_oh_q  <= NL'(1);
      use_next_q <= '0;
      hb_oh_q    <= NB'(1);
      trap_v_q   <= 1'b0;
      trap_idx_q <= '0;
      trap_val_q <= '0;
    end else begin
      prev_ctl_q <= ctl_c;
      prev_blk_q <= blk_c;
      head_q     <= head_d;
      hflag_q    <= hflag_d;
      count_q    <= count_d;
      for (int l = 0; l < NL; l++) head_oh_q[l] <= head_d[IW-1:BW] == LW'(l);
      for (int b = 0; b < NB; b++) hb_oh_q[b] <= head_d[BW-1:0] == BW'(b);
      use_next_q <= use_next_d;
      trap_v_q   <= trap_v_d;
      trap_idx_q <= trap_idx_d;
      trap_val_q <= trap_val_d;
    end
  end

  // waiver: w_valid is the stored valid bit of the window slots; the window position (w_in) is what the logic uses
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ok;
  always_comb begin
    unused_ok = (^w_valid) ^ csr_fs_off;
    for (int i = 0; i < NB; i++) unused_ok = unused_ok ^ (^dis_trap_val[i][ROB_XLEN-1:32]);
  end
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
