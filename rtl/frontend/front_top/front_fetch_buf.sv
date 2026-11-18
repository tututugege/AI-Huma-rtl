// Ref: front-end/front_top.cpp  front_comb_calc S5 (fetch_addr FIFO), S8 (predecode + instruction_FIFO write)
`default_nettype none

// Fetch side buffers of the front end: the fetch-address queue that feeds the icache and the instruction queue that
// receives the predecoded fetch groups coming out of the icache.
//   fetch_addr_fifo      : BPU fetch address in, icache request out
//   predecode + seq pc   : combinational on the icache response (8 lanes, valid-prefix sequential next pc)
//   inst_fifo            : predecoded group in (when the icache completes a read and no refetch), checker side out
module front_fetch_buf import ttg_cfg_pkg::*; import front_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        global_refetch,
  // fetch address queue
  input  logic        fa_rd_en,
  input  logic        fa_wr_en,
  input  logic        fa_drop_tail,
  input  logic [XLEN_BITS-1:0] fa_wr_address,
  output logic        fa_rd_valid,
  output logic [XLEN_BITS-1:0] fa_rd_address,
  output logic        fa_full,
  output logic        fa_empty,
  output logic        fa_head_fresh,
  // icache response
  input  logic        ic_read_complete,
  input  logic [XLEN_BITS-1:0] ic_fetch_pc,
  input  logic [FETCH_WIDTH-1:0] ic_inst_valid,
  input  logic [FETCH_WIDTH-1:0] ic_page_fault_inst,
  input  logic [31:0] ic_fetch_group     [FETCH_WIDTH],
  input  logic [FETCH_WIDTH-1:0] ic_upper_ok,
  // instruction queue read side (head of the queue, valid when predecode_can_run)
  input  logic        inst_rd_en,
  output logic        inst_empty,
  output logic [31:0] inst_rd_instructions            [FETCH_WIDTH],
  output logic [FETCH_WIDTH-1:0] inst_rd_page_fault_inst,
  output logic [FETCH_WIDTH-1:0] inst_rd_inst_valid,
  output logic [1:0]  inst_rd_predecode_type          [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0] inst_rd_predecode_target_address [FETCH_WIDTH],
  output logic [XLEN_BITS-1:0] inst_rd_seq_next_pc,
  output logic [15:0] inst_rd_raw0,
  output logic        inst_rd_up_ok,
  output logic [FETCH_WIDTH-1:0] inst_rd_is_rvc,
  output logic [FETCH_WIDTH-1:0] inst_rd_start_a,
  output logic [FETCH_WIDTH-1:0] inst_rd_start_b
);

  logic [1:0]  predecode_type           [FETCH_WIDTH];
  logic [XLEN_BITS-1:0] predecode_target_address [FETCH_WIDTH];
  logic [XLEN_BITS-1:0] seq_next_pc;
  logic        inst_wr_en;

  // RVC=1: a window whose low bits are not 11 is a 16-bit instruction: it is expanded here (an illegal encoding becomes
  // 0) and marked.  start_a / start_b: which slots begin an instruction when slot 0 begins one / when slot 0 is the
  // second half of the previous group's last instruction (the chain of the valid prefix).
  logic [31:0]            ex_inst [FETCH_WIDTH];
  logic [FETCH_WIDTH-1:0] is_rvc;
  logic [FETCH_WIDTH-1:0] start_a, start_b;
  // RVC=1: the window of the group's last slot carries a real upper halfword (a 32-bit instruction that starts
  // there can be completed from this group)
  logic [FETCH_WIDTH-1:0] last_oh;
  logic                   up_ok;
  always_comb begin
    for (int i = 0; i < FETCH_WIDTH; i++)
      last_oh[i] = ic_inst_valid[i] && ((i == FETCH_WIDTH - 1) ? 1'b1 : !ic_inst_valid[i+1]);
  end
  assign up_ok = (RVC_ENABLE != 0) && |(last_oh & ic_upper_ok);
  if (RVC_ENABLE != 0) begin : g_rvc
    for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_lane
      logic [31:0] ex;
      rvc_expand u_expand (.h(ic_fetch_group[i][15:0]), .inst(ex));
      assign is_rvc[i]  = ic_inst_valid[i] && (ic_fetch_group[i][1:0] != 2'b11);
      assign ex_inst[i] = is_rvc[i] ? ex : ic_fetch_group[i];
    end
    // Instruction starts of the group.  Every instruction is 2 or 4 bytes, so a slot begins one iff the slot before does
    // not begin a 32-bit one: start[i] = valid[i] && (!start[i-1] || is_rvc[i-1]), which toggles along a run of 32-bit
    // instructions and is set right after a 16-bit one.  Slot i therefore begins an instruction iff the distance from the
    // last 16-bit instruction before it is even (the parity of that lane's index): a 4-round prefix scan of "the last
    // set lane and its index parity" instead of a chain over the lanes (checked against the chain by random test).
    //   start_a: slot 0 begins an instruction (no 16-bit one before it counts as an odd lane: parity 1)
    //   start_b: slot 0 is the second half of the previous group's last instruction (slot 1 begins one: lane 0 counts as a
    //            16-bit instruction at an even lane)
    /* verilator lint_off UNUSEDSIGNAL */  // the scan result of the last lane is not used (slot i reads the scan at i-1)
    logic [FETCH_WIDTH-1:0] sc_any_a, sc_par_a, sc_par_b;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
      logic [FETCH_WIDTH-1:0] ca, cb, pa, pb;
      for (int i = 0; i < FETCH_WIDTH; i++) begin
        ca[i] = is_rvc[i];
        cb[i] = (i == 0) ? 1'b1 : is_rvc[i];
        pa[i] = (i % 2) == 1;        // parity of the lane's index
        pb[i] = (i % 2) == 1;
      end
      for (int d = 1; d < FETCH_WIDTH; d = d * 2) begin   // inclusive scan: the last set lane at or below i and its parity
        logic [FETCH_WIDTH-1:0] ca_n, cb_n, pa_n, pb_n;
        ca_n = ca; cb_n = cb; pa_n = pa; pb_n = pb;
        for (int i = d; i < FETCH_WIDTH; i++) begin
          if (!ca[i]) begin ca_n[i] = ca[i-d]; pa_n[i] = pa[i-d]; end
          if (!cb[i]) begin cb_n[i] = cb[i-d]; pb_n[i] = pb[i-d]; end
        end
        ca = ca_n; cb = cb_n; pa = pa_n; pb = pb_n;
      end
      sc_any_a = ca; sc_par_a = pa; sc_par_b = pb;
    end
    for (genvar i = 0; i < FETCH_WIDTH; i++) begin : g_start
      if (i == 0) begin : g_first
        assign start_a[i] = ic_inst_valid[i];
        assign start_b[i] = 1'b0;
      end else begin : g_rest
        // the last 16-bit instruction before slot i (inclusive scan at i-1), none: the virtual one at lane -1 (odd)
        assign start_a[i] = ic_inst_valid[i] && ((sc_any_a[i-1] ? sc_par_a[i-1] : 1'b1) == (((i + 1) % 2) == 1));
        assign start_b[i] = ic_inst_valid[i] && (sc_par_b[i-1] == (((i + 1) % 2) == 1));
      end
    end
  end else begin : g_word
    always_comb begin
      for (int i = 0; i < FETCH_WIDTH; i++) ex_inst[i] = ic_fetch_group[i];
    end
    assign is_rvc  = '0;
    assign start_a = '0;
    assign start_b = '0;
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic [$clog2(FETCH_ADDR_FIFO_DEPTH + 1)-1:0] fa_size_unused;   // occupancy: only the pop rule (head_fresh) is needed outside
  /* verilator lint_on UNUSEDSIGNAL */

  fetch_addr_fifo u_fa_fifo (
    .clk, .rst_n,
    .refetch          (global_refetch),
    .rd_en            (fa_rd_en),
    .wr_en            (fa_wr_en),
    .drop_tail        (fa_drop_tail),
    .wr_fetch_address (fa_wr_address),
    .rd_valid         (fa_rd_valid),
    .rd_fetch_address (fa_rd_address),
    .full             (fa_full),
    .empty            (fa_empty),
    .size             (fa_size_unused),
    .head_fresh       (fa_head_fresh)
  );

  predecode u_predecode (
    .clk, .rst_n,
    .fetch_pc                 (ic_fetch_pc),
    .inst                     (ex_inst),
    .inst_valid               (ic_inst_valid),
    .predecode_type,
    .predecode_target_address
  );

  sequential_next_pc u_seq_next_pc (
    .clk, .rst_n,
    .fetch_pc    (ic_fetch_pc),
    .inst_valid  (ic_inst_valid),
    .seq_next_pc
  );

  // front_top.cpp:1624 `!inst_fifo_full_for_write && icache_slot0_data_valid && !refetch`; the queue can never be full
  // here (instruction entries <= PTAB entries <= 15, frontend-boundary.md 3.4), so the full term is dropped.
  assign inst_wr_en = ic_read_complete && !global_refetch;

  /* verilator lint_off UNUSEDSIGNAL */
  logic inst_full;       // never full (see above); front_fifo asserts against an overflowing write
  logic inst_rd_valid;   // = predecode_can_run, known to the caller
  /* verilator lint_on UNUSEDSIGNAL */
  inst_fifo u_inst_fifo (
    .clk, .rst_n,
    .refetch                     (global_refetch),
    .rd_en                       (inst_rd_en),
    .wr_en                       (inst_wr_en),
    .wr_instructions             (ex_inst),
    .wr_page_fault_inst          (ic_page_fault_inst),
    .wr_inst_valid               (ic_inst_valid),
    .wr_predecode_type           (predecode_type),
    .wr_predecode_target_address (predecode_target_address),
    .wr_seq_next_pc              (seq_next_pc),
    .wr_raw0                     (ic_fetch_group[0][15:0]),
    .wr_up_ok                    (up_ok),
    .wr_is_rvc                   (is_rvc),
    .wr_start_a                  (start_a),
    .wr_start_b                  (start_b),
    .rd_valid                    (inst_rd_valid),
    .rd_instructions             (inst_rd_instructions),
    .rd_page_fault_inst          (inst_rd_page_fault_inst),
    .rd_inst_valid               (inst_rd_inst_valid),
    .rd_predecode_type           (inst_rd_predecode_type),
    .rd_predecode_target_address (inst_rd_predecode_target_address),
    .rd_seq_next_pc              (inst_rd_seq_next_pc),
    .rd_raw0                     (inst_rd_raw0),
    .rd_up_ok                    (inst_rd_up_ok),
    .rd_is_rvc                   (inst_rd_is_rvc),
    .rd_start_a                  (inst_rd_start_a),
    .rd_start_b                  (inst_rd_start_b),
    .full                        (inst_full),
    .empty                       (inst_empty)
  );

endmodule

`default_nettype wire
