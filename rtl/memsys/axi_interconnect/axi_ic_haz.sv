`default_nettype none
// Ref: AXI_Interconnect.cpp  has_same_line_read_hazard
// A write may not be accepted while any read of the same 64-byte line is anywhere in flight (capture slots, stage,
//   request
// ports, LLC lookup / MSHR / memory-read request, AR latch, outstanding DDR reads).
module axi_ic_haz
  import axi_ic_pkg::*;
(
  input  logic [31:0] w_addr [NW],
  // read requests present at the master ports / capture slots / stage
  input  logic        m_rd_valid [NR],
  input  logic [31:0] m_rd_addr  [NR],
  input  logic        up_v       [NR],
  input  logic [31:0] up_addr    [NR],
  input  logic        stage_rd_any,       // stage holds a read
  input  logic [31:0] stage_rd_addr,
  // LLC
  input  logic        hz_lookup_rd,       // lookup valid and not a write
  input  logic [31:0] hz_lookup_addr,
  input  logic        lo_mem_rd_valid,
  input  logic [31:0] lo_mem_rd_addr,
  input  logic        hz_mshr_rd [NM],    // MSHR valid and not a write
  input  logic [31:0] hz_mshr_line [NM],
  // outstanding DDR reads (AR latch + r_pend not yet complete)
  input  logic [NM:0] pr_v,
  input  logic [25:0] pr_line [NM+1],
  output logic        hazard [NW]
);
  for (genvar w = 0; w < NW; w++) begin : g_w
    logic [25:0] ln;
    logic [NR-1:0] a_m, a_u;
    logic [NM-1:0] a_ms;
    logic [NM:0] a_pr;
    assign ln = line64(w_addr[w]);
    for (genvar m = 0; m < NR; m++) begin : g_m
      assign a_m[m] = m_rd_valid[m] && line64(m_rd_addr[m]) == ln;
      assign a_u[m] = up_v[m] && line64(up_addr[m]) == ln;
    end
    for (genvar s = 0; s < NM; s++) begin : g_s
      // exact compare: a bypass MSHR keeps the unaligned request address as line_addr (C++ quirk) and never matches
      assign a_ms[s] = hz_mshr_rd[s] && hz_mshr_line[s] == {ln, 6'b0};
    end
    for (genvar p = 0; p <= NM; p++) begin : g_p
      assign a_pr[p] = pr_v[p] && pr_line[p] == ln;
    end
    assign hazard[w] = (|a_m) || (|a_u) || (|a_ms) || (|a_pr)
                    || (stage_rd_any && line64(stage_rd_addr) == ln)
                    || (hz_lookup_rd && line64(hz_lookup_addr) == ln)
                    || (lo_mem_rd_valid && line64(lo_mem_rd_addr) == ln);
  end
endmodule

`default_nettype wire
