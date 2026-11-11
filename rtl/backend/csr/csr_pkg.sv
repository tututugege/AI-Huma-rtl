// Ref: back-end/Exu/include/Csr.h  enum_number_csr_code / enum_csr
`default_nettype none
/* verilator lint_off UNUSEDPARAM */  // package constants are used by other files
package csr_pkg;
  import ttg_cfg_pkg::*;

  // ---- stored registers (sstatus / sie / sip are views of mstatus / mie / mip and are not stored) ----
  localparam int NREG = 18;
  localparam int R_MTVEC    = 0;
  localparam int R_MEPC     = 1;
  localparam int R_MCAUSE   = 2;
  localparam int R_MIE      = 3;
  localparam int R_MIP      = 4;
  localparam int R_MTVAL    = 5;
  localparam int R_MSCRATCH = 6;
  localparam int R_MSTATUS  = 7;
  localparam int R_MIDELEG  = 8;
  localparam int R_MEDELEG  = 9;
  localparam int R_SEPC     = 10;
  localparam int R_STVEC    = 11;
  localparam int R_SCAUSE   = 12;
  localparam int R_SSCRATCH = 13;
  localparam int R_STVAL    = 14;
  localparam int R_SATP     = 15;
  localparam int R_MHARTID  = 16;
  localparam int R_MISA     = 17;

  // misa: MXL (rv32: 1, rv64: 2) in the top two bits; extensions A(0) B(1) I(8) M(12) S(18) U(20)
  localparam logic [XLEN_BITS-1:0] MISA_RESET =
      XLEN_BITS'((XLEN_BITS == 64) ? 64'h8000000000141103 : 64'h40141103);

  // mstatus reset: rv64 UXL = SXL = 2

  localparam logic [XLEN_BITS-1:0] MSTATUS_RESET = XLEN_BITS'((XLEN_BITS == 64) ? 64'hA00000000 : 64'h0);

  // ---- CSR address table: address, backing register, write mask, read mask ----
  localparam int NENT = 21;
  localparam logic [11:0] ENT_ADDR [NENT] = '{
    12'h305, 12'h341, 12'h342, 12'h304, 12'h344, 12'h343, 12'h340, 12'h300, 12'h303, 12'h302,
    12'h141, 12'h105, 12'h142, 12'h140, 12'h143, 12'h180, 12'hf14, 12'h301,
    12'h100, 12'h104, 12'h144
  };
  localparam int ENT_REG [NENT] = '{
    R_MTVEC, R_MEPC, R_MCAUSE, R_MIE, R_MIP, R_MTVAL, R_MSCRATCH, R_MSTATUS, R_MIDELEG, R_MEDELEG,
    R_SEPC, R_STVEC, R_SCAUSE, R_SSCRATCH, R_STVAL, R_SATP, R_MHARTID, R_MISA,
    R_MSTATUS, R_MIE, R_MIP
  };
  localparam logic [XLEN_BITS-1:0] MSTATUS_WMASK = XLEN_BITS'((XLEN_BITS == 64) ? 64'h7FF9BB : 64'h807FF9BB);
  localparam logic [XLEN_BITS-1:0] SSTATUS_MASK =
      XLEN_BITS'((XLEN_BITS == 64) ? 64'h3000DE133 : 64'h800DE133);  // sstatus read mask
  localparam logic [XLEN_BITS-1:0] SSTATUS_WMASK =
      XLEN_BITS'((XLEN_BITS == 64) ? 64'hDE133 : 64'h800DE133);  // rv64: UXL read-only
  // Interrupt CSRs per the privileged spec (no N extension; same as the function model):
  //   mie / mip hold SSI/MSI/STI/MTI/SEI/MEI (0xAAA), mideleg holds SSI/STI/SEI (0x222),
  //   the supervisor views sie / sip show only the bits delegated by mideleg (ENT_DELEG), and sip can only write SSIP.
  localparam logic [XLEN_BITS-1:0] MIE_WMASK     = XLEN_BITS'(32'h00000AAA);  // mie and mip
  localparam logic [XLEN_BITS-1:0] DELEG_MASK    = XLEN_BITS'(32'h00000222);  // mideleg, and the sie view
  localparam logic [XLEN_BITS-1:0] SIP_WMASK     = XLEN_BITS'(32'h00000002);  // SSIP
  localparam logic [XLEN_BITS-1:0] ALL_ONES      = '1;
  localparam logic [XLEN_BITS-1:0] ENT_WMASK [NENT] = '{
    ALL_ONES, ALL_ONES, ALL_ONES, MIE_WMASK, MIE_WMASK, ALL_ONES, ALL_ONES, MSTATUS_WMASK, DELEG_MASK, ALL_ONES,
    ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES,
    SSTATUS_WMASK, DELEG_MASK, SIP_WMASK
  };
  localparam logic [XLEN_BITS-1:0] ENT_RMASK [NENT] = '{
    ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES,
    ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES, ALL_ONES,
    SSTATUS_MASK, DELEG_MASK, DELEG_MASK
  };
  // entries that are additionally masked by mideleg (sie, sip)
  localparam logic ENT_DELEG [NENT] = '{
    1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
    1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
    1'b0, 1'b1, 1'b1
  };

  // ---- privilege levels ----
  localparam logic [1:0] PRV_U = 2'd0;
  localparam logic [1:0] PRV_S = 2'd1;
  localparam logic [1:0] PRV_M = 2'd3;

  // ---- write command (func3[1:0]) ----
  localparam logic [1:0] WCMD_S = 2'b10;
  localparam logic [1:0] WCMD_C = 2'b11;

  // ---- mstatus bits ----
  localparam int MSTATUS_SIE  = 1;
  localparam int MSTATUS_MIE  = 3;
  localparam int MSTATUS_SPIE = 5;
  localparam int MSTATUS_MPIE = 7;
  localparam int MSTATUS_SPP  = 8;
  localparam int MSTATUS_MPP  = 11;  // [12:11]

  // ---- interrupt kinds: bit positions in mip/mie, index 0=software 1=timer 2=external ----
  localparam int NIRQ = 3;
  localparam int IRQ_M_BIT [NIRQ] = '{3, 7, 11};  // MSIP MTIP MEIP
  localparam int IRQ_S_BIT [NIRQ] = '{1, 5, 9};   // SSIP STIP SEIP
  localparam int MIP_MTIP = 7;
  localparam int MIP_SEIP = 9;
  localparam int MIP_MEIP = 11;

  // ---- medeleg bits ----
  localparam int MEDELEG_ILLEGAL = 2;
  localparam int MEDELEG_BREAKPOINT = 3;
  localparam int MEDELEG_U_ECALL = 8;
  localparam int MEDELEG_S_ECALL = 9;
  localparam int MEDELEG_PF_INST = 12;
  localparam int MEDELEG_PF_LOAD = 13;
  localparam int MEDELEG_PF_STORE = 15;

endpackage
/* verilator lint_on UNUSEDPARAM */
`default_nettype wire
