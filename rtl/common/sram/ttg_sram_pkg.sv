`default_nettype none
// Ref: docs/modules/common.md section 4.1 (SRAM reset sweep). RTL only; the trace-model starts with every
// table at its initial value. The SRAM wrappers (ttg_sram_1rw / ttg_sram_1r1w) hold no reset on their arrays:
// while their rst_n is low they write INIT_VAL to one address per cycle (a wrapping counter with no reset, so
// any power-on value works); after DEPTH + 1 cycles of reset every address has been written. ttg_rst_sweep
// (soc_top, soc_crg) holds the reset of the whole design for SRAM_SWEEP_CYCLES cycles after the external
// reset is released, so every wrapper with DEPTH + 1 <= SRAM_SWEEP_CYCLES (checked at elaboration) is cleared.
package ttg_sram_pkg;
  // deepest swept wrapper: the LLC tables (axi_llc_pkg::SETS = 4096); +1 for a counter starting out of range, +3 spare
  localparam int SRAM_SWEEP_CYCLES = 4100;
endpackage
`default_nettype wire
