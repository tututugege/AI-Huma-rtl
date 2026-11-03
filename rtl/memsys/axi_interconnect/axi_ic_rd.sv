`default_nettype none
// Ref: AXI_Interconnect.cpp  AXI_Interconnect::comb_read_arbiter (LLC branch), has_read_id_conflict
// Read-master capture with the ready-first handshake.  Per master m (all independent):
//   cand      = req valid, capture slot free, no stage entry of this master, no id conflict
//   accept    = cand and (m == DCACHE_R  or  ready register already set)      -> capture request into the upstream slot
//   ready_o2  = cand                                                          (ready is raised either way)
// ready_r' = cand and not accepted                                          (only DCache every tick, others on
//   tick 0)
module axi_ic_rd
  import axi_ic_pkg::*;
(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        phase0,
  // master requests (comb_inputs time)
  input  logic        m_valid [NR],
  input  logic [31:0] m_addr  [NR],
  input  logic [7:0]  m_size  [NR],
  input  logic [3:0]  m_id    [NR],
  input  logic        m_byp   [NR],
  // interconnect state seen by the id-conflict check
  input  logic        up_v        [NR],   // upstream capture slot valid
  input  logic [3:0]  up_id       [NR],
  input  logic        stage_rd_v  [NR],   // stage holds a read of this master
  input  logic [3:0]  stage_rd_id,
  input  logic        rr_v        [NR],   // local read-response register valid
  input  logic [3:0]  rr_id       [NR],
  input  logic [NM-1:0] rp_v,             // r_pend slot valid (orig_id = slot index, master_id 0)
  // LLC registers
  input  logic        hz_rresp_valid [NR],
  input  logic [3:0]  hz_rresp_id    [NR],
  input  logic        hz_lookup_valid,
  input  logic [1:0]  hz_lookup_master,
  input  logic [3:0]  hz_lookup_id,
  input  logic        hz_mshr_valid  [NM],
  input  logic [1:0]  hz_mshr_master [NM],
  input  logic [3:0]  hz_mshr_id     [NM],
  // outputs
  output logic        acc      [NR],      // capture this tick
  output logic [31:0] cap_addr [NR],
  output logic [7:0]  cap_size [NR],
  output logic [3:0]  cap_id   [NR],
  output logic        cap_byp  [NR],
  output logic        ready_o2 [NR]
);
  logic ready_q [NR];                     // req_ready_r (ready-first handshake register)

  for (genvar m = 0; m < NR; m++) begin : g_m
    logic [NM-1:0] ms_conf;
    for (genvar s = 0; s < NM; s++) begin : g_ms
      assign ms_conf[s] = hz_mshr_valid[s] && (hz_mshr_master[s] == 2'(m)) && (hz_mshr_id[s] == m_id[m]);
    end
    // r_pending orig_id is the LLC mem id (< NM) and its master_id is always 0: only master 0 can collide (C++ quirk).
    logic rp_conf, conflict, cand, take_now;
    assign rp_conf = (m == 0) && (m_id[m][3] == 1'b0) && rp_v[m_id[m][MW-1:0]];
    assign conflict = rp_conf
                   || (stage_rd_v[m] && stage_rd_id == m_id[m])
                   || (up_v[m] && up_id[m] == m_id[m])
                   || (rr_v[m] && rr_id[m] == m_id[m])
                   || (hz_rresp_valid[m] && hz_rresp_id[m] == m_id[m])
                   || (hz_lookup_valid && hz_lookup_master == 2'(m) && hz_lookup_id == m_id[m])
                   || (|ms_conf);
    assign cand     = m_valid[m] && !up_v[m] && !stage_rd_v[m] && !conflict;
    assign take_now = (m == MASTER_DCACHE_R) || ready_q[m];
    assign acc[m]      = cand && take_now;
    assign ready_o2[m] = cand;
    assign cap_addr[m] = m_addr[m];
    assign cap_size[m] = m_size[m];
    assign cap_id[m]   = m_id[m];
    assign cap_byp[m]  = m_byp[m];
    // ready register: DCache master every tick; the others only on the CPU tick (restore_..._except_dcache)
    if (m == MASTER_DCACHE_R) begin : g_dc
      always_ff @(posedge clk) begin
        if (!rst_n) ready_q[m] <= 1'b0;
        else        ready_q[m] <= cand && !take_now;
      end
    end else begin : g_cpu
      always_ff @(posedge clk) begin
        if (!rst_n)       ready_q[m] <= 1'b0;
        else if (phase0)  ready_q[m] <= cand && !take_now;
      end
    end
  end
endmodule

`default_nettype wire
