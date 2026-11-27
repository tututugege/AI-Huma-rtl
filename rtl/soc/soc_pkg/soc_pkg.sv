// Ref: docs/modules/chip_top.md  AI-Huma SoC v1 address map, slave IDs, and IRQ map
`default_nettype none
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
package soc_pkg;

  // ---- SoC slave IDs (decoded by soc_xbar) ----
  localparam int NSLV_MMIO   = 6;
  localparam int SLV_DDR     = 0;   // 0x8000_0000 .. 0xFFFF_FFFF (2 GiB external DDR)
  localparam int SLV_BOOTROM = 1;   // 0x0000_0000 .. 0x0000_0FFF (4 KiB BootROM)
  localparam int SLV_CLINT   = 2;   // 0x0200_0000..0x0200_FFFF & 0x1FD0_E000..0x1FD0_EFFF
  localparam int SLV_PLIC    = 3;   // 0x0C00_0000 .. 0x0FFF_FFFF (64 MiB standard RISC-V PLIC)
  localparam int SLV_UART    = 4;   // 0x1000_0000 .. 0x1000_0FFF (NS16550A UART)
  localparam int SLV_SYSCTRL = 5;   // 0x1F00_0000 .. 0x1F00_0FFF (SysCtrl)
  localparam int SLV_SRAM    = 6;   // 0x3000_0000 .. 0x3000_FFFF (64 KiB On-Chip SRAM)
  localparam int SLV_ERR     = 7;   // unmapped -> DECERR (2'b11)

  // ---- Base addresses ----
  localparam logic [31:0] ADDR_BOOTROM_BASE = 32'h0000_0000;
  localparam logic [31:0] ADDR_CLINT_STD    = 32'h0200_0000;
  localparam logic [31:0] ADDR_PLIC_BASE    = 32'h0C00_0000;
  localparam logic [31:0] ADDR_UART_BASE    = 32'h1000_0000;
  localparam logic [31:0] ADDR_SYSCTRL_BASE = 32'h1F00_0000;
  localparam logic [31:0] ADDR_CLINT_DTS    = 32'h1FD0_E000;
  localparam logic [31:0] ADDR_SRAM_BASE    = 32'h3000_0000;
  localparam logic [31:0] ADDR_DDR_BASE     = 32'h8000_0000;

  // ---- PLIC IRQ assignments (1-indexed per RISC-V PLIC spec) ----
  localparam int PLIC_NUM_SRC = 8;
  localparam int IRQ_UART     = 1;

  // ---- AXI response codes ----
  localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam logic [1:0] AXI_RESP_DECERR = 2'b11;

  // ---- Address decoder ----
  function automatic logic [2:0] soc_decode_slave(input logic [31:0] addr);
    if (addr[31])                        return 3'(SLV_DDR);
    else if (addr[31:12] == 20'h00000)   return 3'(SLV_BOOTROM);
    else if (addr[31:16] == 16'h0200)    return 3'(SLV_CLINT);
    else if (addr[31:12] == 20'h1FD0E)   return 3'(SLV_CLINT);
    else if (addr[31:26] == 6'b0000_11)  return 3'(SLV_PLIC);
    else if (addr[31:12] == 20'h10000)   return 3'(SLV_UART);
    else if (addr[31:12] == 20'h1F000)   return 3'(SLV_SYSCTRL);
    else if (addr[31:16] == 16'h3000)    return 3'(SLV_SRAM);
    else                                 return 3'(SLV_ERR);
  endfunction

endpackage
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
`default_nettype wire
