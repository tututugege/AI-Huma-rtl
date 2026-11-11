// Ref: MemSubSystem/PeripheralAxi.cpp  PeripheralAxi::comb_outputs / comb_inputs / seq
`default_nettype none

// Peripheral access FSM.  One request at a time:
//   idle     : accept a request; addresses of devices modeled by the environment are served locally and
//              answered the next cycle, everything else is issued on the AXI master (busy)
//   busy     : request channel until accepted, then wait for the response, then answer
//   resp_valid cycle : the answer is visible (resp_is_mmio / resp_rdata), no request is taken
// The response towards the LSU is registered state only (resp_ready = idle, resp_rdata = rdata_q).
module peripheral_axi_ctl import memcpu_pkg::*; (
  input  logic clk,
  input  logic rst_n,
  input  logic cpu_en,
  // LSU request
  input  logic        req_is_mmio,
  input  logic        req_wen,
  input  logic [31:0] req_addr,
  input  logic [31:0] req_wdata,
  input  logic [2:0]  req_func3,
  // environment
  input  logic        env_modeled,       // the address is a device modeled by the environment (else AXI)
  input  logic [31:0] env_rdata,
  // AXI
  input  logic        axi_rd_req_accepted,
  input  logic        axi_rd_resp_valid,
  input  logic        axi_wr_req_accepted,
  input  logic        axi_wr_resp_valid,
  // formatting of the registered access / of the response word
  output logic [2:0]  fmt_func3,
  output logic [31:0] fmt_wdata,
  input  logic [PA_SIZE_W-1:0] fmt_size,
  input  logic [3:0]  fmt_wstrb,
  input  logic [31:0] fmt_wdata_packed,
  input  logic [31:0] fmt_rdata_ext,
  // outputs
  output logic        resp_ready,
  output logic        resp_is_mmio,
  output logic [31:0] resp_rdata,
  output logic        axi_rd_req_valid,
  output logic [31:0] axi_rd_req_addr,
  output logic [PA_SIZE_W-1:0] axi_rd_req_size,
  output logic        axi_rd_resp_ready,
  output logic        axi_wr_req_valid,
  output logic [31:0] axi_wr_req_addr,
  output logic [PA_SIZE_W-1:0] axi_wr_req_size,
  output logic [3:0]  axi_wr_req_wstrb,
  output logic [31:0] axi_wr_req_wdata,
  output logic        axi_wr_resp_ready,
  output logic        env_rd_en,
  output logic [31:0] env_rd_addr,
  output logic [2:0]  env_rd_func3
);

  logic        busy_q, write_q, accepted_q, resp_valid_q;
  logic [31:0] addr_q, wdata_q, rdata_q;
  logic [2:0]  func3_q;

  assign fmt_func3 = func3_q;
  assign fmt_wdata = wdata_q;

  // ---- outputs: registered state only ----
  wire idle = !busy_q && !resp_valid_q;
  assign resp_ready   = idle;
  assign resp_is_mmio = resp_valid_q;
  assign resp_rdata   = rdata_q;

  wire send_req = busy_q && !accepted_q;
  wire wait_rsp = busy_q && accepted_q;
  assign axi_rd_req_valid  = send_req && !write_q;
  assign axi_rd_req_addr   = addr_q;
  assign axi_rd_req_size   = fmt_size;
  assign axi_rd_resp_ready = wait_rsp && !write_q;
  assign axi_wr_req_valid  = send_req && write_q;
  assign axi_wr_req_addr   = addr_q;
  assign axi_wr_req_size   = fmt_size;
  assign axi_wr_req_wstrb  = fmt_wstrb;
  assign axi_wr_req_wdata  = fmt_wdata_packed;
  assign axi_wr_resp_ready = wait_rsp && write_q;

  // ---- request acceptance (idle only) ----
  wire accept      = idle && req_is_mmio;
  wire local_serve = accept && env_modeled;
  wire axi_issue   = accept && !env_modeled;
  assign env_rd_en    = local_serve && !req_wen;
  assign env_rd_addr  = req_addr;
  assign env_rd_func3 = req_func3;

  // ---- AXI progress ----
  wire req_taken = send_req && (write_q ? axi_wr_req_accepted : axi_rd_req_accepted);
  wire rsp_done  = wait_rsp && (write_q ? axi_wr_resp_valid : axi_rd_resp_valid);

  logic busy_d, accepted_d, resp_valid_d;
  logic [31:0] rdata_d;
  always_comb begin
    busy_d       = busy_q;
    accepted_d   = accepted_q;
    resp_valid_d = 1'b0;       // the answer lasts exactly one cycle
    rdata_d      = rdata_q;
    if (axi_issue) begin
      busy_d     = 1'b1;
      accepted_d = 1'b0;
      rdata_d    = 32'd0;
    end else if (local_serve) begin
      resp_valid_d = 1'b1;
      rdata_d      = req_wen ? 32'd0 : env_rdata;
    end else if (req_taken) begin
      accepted_d = 1'b1;
    end else if (rsp_done) begin
      busy_d       = 1'b0;
      accepted_d   = 1'b0;
      resp_valid_d = 1'b1;
      rdata_d      = write_q ? 32'd0 : fmt_rdata_ext;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      busy_q       <= 1'b0;
      write_q      <= 1'b0;
      accepted_q   <= 1'b0;
      resp_valid_q <= 1'b0;
      addr_q       <= 32'd0;
      wdata_q      <= 32'd0;
      rdata_q      <= 32'd0;
      func3_q      <= 3'd0;
    end else if (cpu_en) begin
      busy_q       <= busy_d;
      accepted_q   <= accepted_d;
      resp_valid_q <= resp_valid_d;
      rdata_q      <= rdata_d;
      if (accept) begin          // the request is latched whichever way it is served
        write_q <= req_wen;
        addr_q  <= req_addr;
        wdata_q <= req_wdata;
        func3_q <= req_func3;
      end
    end
  end

endmodule

`default_nettype wire
