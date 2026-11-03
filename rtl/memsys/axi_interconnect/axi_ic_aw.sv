`default_nettype none
// Ref: AXI_Interconnect.cpp  comb_write_request (LLC memory write issue, drive_aw_latch, drive_w_current),
//   comb_write_response,
//      seq (AW/W/B handshakes, llc_mem_write_resp_), prepare_llc_inputs (mem.write_req_ready / write_resp)
// DDR write side, used only by the LLC (victim / bypass write-back): AW is driven straight from the LLC request
//   (latched when
// awready is low), W beats follow once AW is accepted, the B response is handed to the LLC as a one-tick
//   write_resp pulse.
module axi_ic_aw
  import axi_ic_pkg::*;
(
  input  logic          clk,
  input  logic          rst_n,
  // LLC memory write request
  input  logic          lo_valid,
  input  logic [31:0]   lo_addr,
  input  logic [511:0]  lo_data,
  input  logic [63:0]   lo_strb,
  input  logic [7:0]    lo_size,
  input  logic [3:0]    lo_id,
  // pending DDR reads (hazard against a new AW): AR latch + r_pend incomplete + AR issued this tick
  input  logic [NM:0]   pr_v,
  input  logic [25:0]   pr_line [NM+1],
  input  logic          fr_v,
  input  logic [25:0]   fr_line,
  // DDR write channels
  input  logic          d_awready,
  input  logic          d_wready,
  input  logic          d_bvalid,
  input  logic [5:0]    d_bid,
  input  logic [1:0]    d_bresp,
  output logic          o_awvalid,
  output logic [5:0]    o_awid,
  output logic [31:0]   o_awaddr,
  output logic          o_awlen,
  output logic          o_wvalid,
  output logic [255:0]  o_wdata,
  output logic [31:0]   o_wstrb,
  output logic          o_wlast,
  output logic          o_bready,
  // to the LLC
  output logic          li_wr_ready,
  output logic          li_resp_valid,
  output logic [1:0]    li_resp,
  // pending-write views for the AR hazard check
  output logic          wp_v    [2],
  output logic [25:0]   wp_line [2]
);
  typedef struct packed {
    logic v;
    logic [31:0] addr;
    logic len;
    logic [5:0] id;
  } awl_t;
  typedef struct packed {
    logic act, awdone, wdone;
    logic [5:0] id;
    logic [31:0] addr;
    logic tot2;
    logic [1:0] sent;
    logic [511:0] data;
    logic [63:0] strb;
  } wcur_t;

  awl_t   awl_q, awl_d;
  wcur_t  w_q, w_d;
  logic        rsp_v_q, rsp_v_d;
  logic [1:0]  rsp_q;

  // can_issue_external_write: no read of the same 64-byte line outstanding or being issued
  logic [NM:0] hit_pr;
  logic        rd_haz;
  always_comb begin
    for (int p = 0; p <= NM; p++) hit_pr[p] = pr_v[p] && pr_line[p] == line64(lo_addr);
    rd_haz = (|hit_pr) || (fr_v && fr_line == line64(lo_addr));
  end

  logic fresh;
  assign fresh = !rsp_v_q && lo_valid && !rd_haz && !w_q.act && !awl_q.v;
  assign li_wr_ready   = !w_q.act && !awl_q.v && !rsp_v_q && (!lo_valid || !rd_haz);
  assign li_resp_valid = rsp_v_q;
  assign li_resp       = rsp_q;

  assign wp_v[0]    = awl_q.v;
  assign wp_line[0] = line64(awl_q.addr);
  assign wp_v[1]    = w_q.act;
  assign wp_line[1] = line64(w_q.addr);

  // AW: latch has priority, else straight from the LLC request (issue shape: <= 32 bytes -> one aligned beat)
  assign o_awvalid = awl_q.v || fresh;
  assign o_awid    = awl_q.v ? awl_q.id   : {2'b0, lo_id};
  assign o_awaddr  = awl_q.v ? awl_q.addr : issue_addr(lo_addr, lo_size);
  assign o_awlen   = awl_q.v ? awl_q.len  : issue_len(lo_size);

  // W beats
  assign o_wvalid = w_q.act && w_q.awdone && !w_q.wdone;
  assign o_wdata  = w_q.sent[0] ? w_q.data[511:256] : w_q.data[255:0];
  assign o_wstrb  = w_q.sent[0] ? w_q.strb[63:32]   : w_q.strb[31:0];
  assign o_wlast  = (w_q.sent == (w_q.tot2 ? 2'd1 : 2'd0));
  assign o_bready = w_q.act && w_q.wdone && (w_q.id == d_bid) && !rsp_v_q;

  // small writes are shifted to their byte position inside the aligned 32-byte beat
  //   (align_mode2_downstream_write_data/strobe)
  logic [511:0] sh_data;
  logic [63:0]  sh_strb;
  assign sh_data = issue_small(lo_size) ? (lo_data << {lo_addr[4:0], 3'b000}) : lo_data;
  assign sh_strb = issue_small(lo_size) ? (lo_strb << lo_addr[4:0]) : lo_strb;

  logic aw_hs, w_hs, b_hs;
  assign aw_hs = o_awvalid && d_awready;
  assign w_hs  = o_wvalid && d_wready;
  assign b_hs  = d_bvalid && o_bready;

  always_comb begin
    awl_d = awl_q;
    w_d   = w_q;
    if (fresh) begin
      w_d = '{act: 1'b1, awdone: 1'b0, wdone: 1'b0, id: {2'b0, lo_id}, addr: issue_addr(lo_addr, lo_size),
              tot2: issue_len(lo_size), sent: 2'd0, data: sh_data, strb: sh_strb};
      awl_d = '{v: 1'b1, addr: issue_addr(lo_addr, lo_size), len: issue_len(lo_size), id: {2'b0, lo_id}};
    end
    if (aw_hs) begin
      awl_d.v   = 1'b0;
      w_d.awdone = 1'b1;
    end
    if (w_hs) begin
      w_d.sent = w_q.sent + 2'd1;
      if (o_wlast) w_d.wdone = 1'b1;
    end
    if (b_hs) w_d = '0;
    rsp_v_d = b_hs;                      // one-tick pulse (cleared again by the next seq)
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      awl_q <= '0; w_q <= '0; rsp_v_q <= 1'b0; rsp_q <= 2'd0;
    end else begin
      awl_q <= awl_d; w_q <= w_d; rsp_v_q <= rsp_v_d;
      if (b_hs) rsp_q <= d_bresp;
      else if (rsp_v_q) rsp_q <= 2'd0;
    end
  end
endmodule

`default_nettype wire
