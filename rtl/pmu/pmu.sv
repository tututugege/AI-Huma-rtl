// Ref: (new, EXP-013) pmu -- hardware performance monitoring unit: counters + RISC-V HPM CSR block
// Event bus in (one small per-cycle increment per event, ids from pmu_ev_pkg), counters out through the standard
// machine-mode counter CSRs. The whole thing is: 2 fixed 64-bit counters (mcycle, minstret), NUM_HPM programmable
// 64-bit counters (each = event select register + an PMU_NUM_EV:1 mux of the PMU_INC_W-bit increments + a 64-bit
// adder), mcountinhibit, mcounteren. No overflow interrupt (counters are 64 bits wide).
`default_nettype none

module pmu
  import pmu_ev_pkg::*;
#(
  parameter int NUM_HPM = 8  // programmable counters: mhpmcounter3 .. mhpmcounter(2+NUM_HPM), at most 29
) (
  input  logic                                clk,
  input  logic                                rst_n,
  // event bus: lane i carries the increment of event i this cycle
  input  logic [PMU_NUM_EV-1:0][PMU_INC_W-1:0] ev_inc,
  // CSR port (driven by the CSR unit at commit of a CSR instruction)
  input  logic [11:0]                         csr_addr,
  input  logic                                csr_wen,       // write (one cycle, at commit)
  input  logic [31:0]                         csr_wdata,
  input  logic                                csr_prv_m,     // current privilege is machine mode
  output logic                                csr_hit,       // the address belongs to the PMU
  output logic [31:0]                         csr_rdata,
  output logic                                csr_illegal    // not allowed (-> illegal instruction)
);

  localparam int NCNT = 2 + NUM_HPM;  // index 0 = cycle, 1 = instret, 2.. = hpm counters 3..
  // mcountinhibit / mcounteren bits in use: 0 CY, 2 IR, 3+k HPM k (bit 1 is reserved)
  localparam int NBIT = NCNT + 1;

  localparam logic [11:0] A_MCOUNTEREN   = 12'h306;
  localparam logic [11:0] A_MCOUNTINHIBIT = 12'h320;
  localparam logic [11:0] A_MHPMEVENT3   = 12'h323;
  localparam logic [11:0] A_MCYCLE       = 12'hB00;
  localparam logic [11:0] A_MINSTRET     = 12'hB02;
  localparam logic [11:0] A_MHPMCOUNTER3 = 12'hB03;
  localparam logic [11:0] A_MCYCLEH      = 12'hB80;
  localparam logic [11:0] A_MINSTRETH    = 12'hB82;
  localparam logic [11:0] A_MHPMCOUNTER3H = 12'hB83;
  localparam logic [11:0] A_CYCLE        = 12'hC00;
  localparam logic [11:0] A_INSTRET      = 12'hC02;
  localparam logic [11:0] A_HPMCOUNTER3  = 12'hC03;
  localparam logic [11:0] A_CYCLEH       = 12'hC80;
  localparam logic [11:0] A_INSTRETH     = 12'hC82;
  localparam logic [11:0] A_HPMCOUNTER3H = 12'hC83;

  // ---- state ----
  logic [63:0]                cnt_q [NCNT];
  logic [63:0]                cnt_d [NCNT];
  logic [7:0]                 hpm_event_q [NUM_HPM];
  logic [7:0]                 hpm_event_d [NUM_HPM];
  // mcountinhibit layout: bit 0 CY, bit 1 unused, bit 2 IR, bit 3+k HPM k
  logic [NBIT-1:0]            inhibit_q, inhibit_d;
  logic [NBIT-1:0]            counteren_q, counteren_d;

  // mcountinhibit / mcounteren bit i belongs to counter index: CY -> bit 0, IR -> bit 2, hpm k -> bit 3+k
  function automatic int csr_bit_of(input int idx);
    return (idx == 0) ? 0 : (idx == 1) ? 2 : (idx + 1);
  endfunction

  // ---- increments ----
  logic [PMU_INC_W-1:0] inc [NCNT];
  always_comb begin
    inc[0] = ev_inc[PMU_EV_CYCLES];
    inc[1] = ev_inc[PMU_EV_INSTRET];
    for (int k = 0; k < NUM_HPM; k++) begin
      inc[2+k] = '0;
      for (int e = 0; e < PMU_NUM_EV; e++)
        if (hpm_event_q[k] == 8'(e + 1)) inc[2+k] = ev_inc[e];
    end
  end

  // ---- CSR decode ----
  // counter index of an address in a bank (low/high), -1 if the address is not a counter of this PMU
  function automatic int counter_idx(input logic [11:0] a, input logic [11:0] base_cycle,
                                     input logic [11:0] base_instret, input logic [11:0] base_hpm3);
    if (a == base_cycle) return 0;
    if (a == base_instret) return 1;
    for (int k = 0; k < NUM_HPM; k++) if (a == base_hpm3 + 12'(k)) return 2 + k;
    return -1;
  endfunction

  int m_lo, m_hi, u_lo, u_hi, ev_k;
  always_comb begin
    m_lo = counter_idx(csr_addr, A_MCYCLE, A_MINSTRET, A_MHPMCOUNTER3);
    m_hi = counter_idx(csr_addr, A_MCYCLEH, A_MINSTRETH, A_MHPMCOUNTER3H);
    u_lo = counter_idx(csr_addr, A_CYCLE, A_INSTRET, A_HPMCOUNTER3);
    u_hi = counter_idx(csr_addr, A_CYCLEH, A_INSTRETH, A_HPMCOUNTER3H);
    ev_k = -1;
    for (int k = 0; k < NUM_HPM; k++) if (csr_addr == A_MHPMEVENT3 + 12'(k)) ev_k = k;
  end

  logic is_mcounteren, is_inhibit, is_event, is_mcnt, is_ucnt;
  always_comb begin
    is_mcounteren = (csr_addr == A_MCOUNTEREN);
    is_inhibit    = (csr_addr == A_MCOUNTINHIBIT);
    is_event      = (ev_k >= 0);
    is_mcnt       = (m_lo >= 0) || (m_hi >= 0);
    is_ucnt       = (u_lo >= 0) || (u_hi >= 0);
    csr_hit       = is_mcounteren || is_inhibit || is_event || is_mcnt || is_ucnt;
  end

  // ---- read ----
  always_comb begin
    csr_rdata = '0;
    csr_illegal = 1'b0;
    if (csr_hit && !csr_prv_m && !is_ucnt) csr_illegal = 1'b1;  // machine-only registers
    if (is_mcounteren) csr_rdata = 32'(counteren_q);
    else if (is_inhibit) csr_rdata = 32'(inhibit_q);
    else if (is_event) csr_rdata = 32'(hpm_event_q[ev_k]);
    else if (m_lo >= 0) csr_rdata = cnt_q[m_lo][31:0];
    else if (m_hi >= 0) csr_rdata = cnt_q[m_hi][63:32];
    else if (is_ucnt) begin  // read-only user shadow, enabled per counter by mcounteren outside machine mode
      automatic int idx = (u_lo >= 0) ? u_lo : u_hi;
      csr_rdata = (u_lo >= 0) ? cnt_q[idx][31:0] : cnt_q[idx][63:32];
      if (!csr_prv_m && !counteren_q[csr_bit_of(idx)]) csr_illegal = 1'b1;
      if (csr_wen) csr_illegal = 1'b1;  // the shadows are read-only
    end
  end

  // ---- next state ----
  always_comb begin
    for (int i = 0; i < NCNT; i++) begin
      cnt_d[i] = cnt_q[i];
      if (!inhibit_q[csr_bit_of(i)]) cnt_d[i] = cnt_q[i] + 64'(inc[i]);
    end
    for (int k = 0; k < NUM_HPM; k++) hpm_event_d[k] = hpm_event_q[k];
    inhibit_d = inhibit_q;
    counteren_d = counteren_q;
    if (csr_wen && csr_prv_m) begin
      if (is_mcounteren) for (int i = 0; i < NCNT; i++) counteren_d[csr_bit_of(i)] = csr_wdata[csr_bit_of(i)];
      if (is_inhibit)    for (int i = 0; i < NCNT; i++) inhibit_d[csr_bit_of(i)] = csr_wdata[csr_bit_of(i)];
      if (is_event)      hpm_event_d[ev_k] = csr_wdata[7:0];
      if (m_lo >= 0)     cnt_d[m_lo][31:0] = csr_wdata;   // a write wins over this cycle's increment
      if (m_hi >= 0)     cnt_d[m_hi][63:32] = csr_wdata;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < NCNT; i++) cnt_q[i] <= '0;
      for (int k = 0; k < NUM_HPM; k++) hpm_event_q[k] <= '0;
      inhibit_q <= '0;
      counteren_q <= '0;
    end else begin
      for (int i = 0; i < NCNT; i++) cnt_q[i] <= cnt_d[i];
      for (int k = 0; k < NUM_HPM; k++) hpm_event_q[k] <= hpm_event_d[k];
      inhibit_q <= inhibit_d;
      counteren_q <= counteren_d;
    end
  end

endmodule

`default_nettype wire
