// Ref: docs/modules/chip_top.md  SoC Clock & Reset Generator (CRG)
`default_nettype none

// Resets and slow-clock CDC for chip_top:
//   sys_rst_n : async-assert, sync-deassert in clk_core (combines por_rst_n, ext_ndmreset, sw_rst_req), then
//               held SRAM_SWEEP_CYCLES more cycles so every SRAM wrapper clears its array (common.md 4.1)
//   rtc_tick  : 1-cycle synchronized rising-edge pulse of clk_rtc in clk_core
//   dft_test_mode / dft_scan_en : DFT reset bypass hooks for scan/ATPG
module soc_crg (
  input  logic clk_core,
  input  logic clk_rtc,
  input  logic por_rst_n,
  input  logic ext_ndmreset,
  input  logic sw_rst_req,
  input  logic dft_test_mode,
  input  logic dft_scan_en,
  output logic sys_rst_n,
  output logic rtc_tick
);

  logic raw_sys_rst_n;
  assign raw_sys_rst_n = dft_test_mode ? por_rst_n : (por_rst_n & ~ext_ndmreset & ~sw_rst_req);

  logic sync_rst_n;
  soc_rst_sync u_sys_rst (
    .clk(clk_core), .raw_rst_n(raw_sys_rst_n), .dft_test_mode(dft_test_mode), .rst_n(sync_rst_n)
  );
  /* verilator lint_off PINCONNECTEMPTY */
  logic swept_rst_n;
  ttg_rst_sweep u_rst_sweep (.clk(clk_core), .rst_n_i(sync_rst_n), .rst_n_o(swept_rst_n), .init_done());
  /* verilator lint_on PINCONNECTEMPTY */
  assign sys_rst_n = dft_test_mode ? sync_rst_n : swept_rst_n;   // scan: reset controllable from the pin

  soc_cdc_pulse u_rtc_tick (
    .dst_clk(clk_core), .dst_rst_n(sys_rst_n), .src_sig(clk_rtc), .pulse_out(rtc_tick)
  );

  logic unused_dft;
  assign unused_dft = dft_scan_en;

endmodule

`default_nettype wire
