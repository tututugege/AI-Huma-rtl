`default_nettype none
// Ref: axi-interconnect-kit/axi_interconnect/include/AXI_Interconnect.h  (AXI_Interconnect_IO.h masters,
//   AXI_Interconnect class state)
// Constants and helpers of the AXI interconnect (LLC-enabled live paths only, docs/modules/axi_interconnect.md).

`ifndef AXI_LLC_MSHR
`define AXI_LLC_MSHR 8
`endif

// lint: line64 / issue_* helpers use only part of their argument.
/* verilator lint_off UNUSEDSIGNAL */
package axi_ic_pkg;
  /* verilator lint_off UNUSEDPARAM */
  localparam int NR = 4;               // read masters: ICache, DCache MSHR, UNCORE_LSU (unused), peripheral
  localparam int NW = 2;               // write masters: DCache WB, peripheral
  localparam int NM = `AXI_LLC_MSHR;   // LLC MSHR slots = max in-flight DDR reads (index = LLC mem id)
  localparam int MW = $clog2(NM);
  localparam int MASTER_DCACHE_R = 1;
  localparam int MASTER_DCACHE_W = 0;
  /* verilator lint_on UNUSEDPARAM */

  // 64-byte line number of an address (AXI_LLC::line_addr / external_hazard_line_addr granule)
  function automatic logic [25:0] line64(input logic [31:0] a);
    return a[31:6];
  endfunction

  // Downstream issue shape (axi_bridge_downstream_read/write_issue_shape, force_ddr_aligned=0, DDR port, 32 B beats):
  // a request of <= 32 bytes is issued as ONE 32-byte aligned beat (the response is shifted back), a larger one
  //   unchanged.
  function automatic logic issue_small(input logic [7:0] size);
    return size < 8'd32;
  endfunction

  function automatic logic [31:0] issue_addr(input logic [31:0] addr, input logic [7:0] size);
    return issue_small(size) ? {addr[31:5], 5'b0} : addr;
  endfunction

  // AXI burst length (beats - 1) for a request of total_size+1 bytes over 32-byte beats; sizes <= 64 bytes only.
  function automatic logic issue_len(input logic [7:0] size);
    return !issue_small(size);
  endfunction
endpackage
/* verilator lint_on UNUSEDSIGNAL */

`default_nettype wire
