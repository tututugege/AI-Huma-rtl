// Ref: function-model/include/rvc.h  rvc::expand (the same case structure, XLEN and HAS_FP from the configuration)
`default_nettype none

// Expansion of a 16-bit compressed instruction into the equivalent 32-bit instruction.  An illegal / reserved
// encoding gives 0 (all zero is an illegal 32-bit instruction: the back end raises the illegal-instruction exception).
// rv64: c.addiw/c.subw/c.addw/c.ld/c.sd/c.ldsp/c.sdsp.
module rvc_expand_ref import ttg_cfg_pkg::*; #(
  parameter int IS_RV64 = (XLEN_BITS == 64) ? 1 : 0,
  parameter int HAS_FP  = (FPRF_NUM != 0) ? 1 : 0
) (
  input  logic [15:0] h,
  output logic [31:0] inst
);

  localparam bit RV64 = (IS_RV64 != 0);
  localparam bit FPEN = (HAS_FP != 0);

  localparam logic [6:0] LOAD = 7'h03, STORE = 7'h23, OPIMM = 7'h13, OP = 7'h33, OPIMMW = 7'h1b, OPW = 7'h3b,
                         LOADFP = 7'h07, STOREFP = 7'h27;

  /* verilator lint_off UNUSEDSIGNAL */   // the offsets of b / j instructions have bit 0 = 0
  function automatic logic [31:0] enc_i(input logic [6:0] opc, input logic [4:0] rd, input logic [2:0] f3,
                                        input logic [4:0] rs1, input logic [11:0] imm);
    return {imm, rs1, f3, rd, opc};
  endfunction
  function automatic logic [31:0] enc_r(input logic [6:0] opc, input logic [4:0] rd, input logic [2:0] f3,
                                        input logic [4:0] rs1, input logic [4:0] rs2, input logic [6:0] f7);
    return {f7, rs2, rs1, f3, rd, opc};
  endfunction
  function automatic logic [31:0] enc_s(input logic [6:0] opc, input logic [2:0] f3, input logic [4:0] rs1,
                                        input logic [4:0] rs2, input logic [11:0] imm);
    return {imm[11:5], rs2, rs1, f3, imm[4:0], opc};
  endfunction
  function automatic logic [31:0] enc_b(input logic [2:0] f3, input logic [4:0] rs1, input logic [4:0] rs2,
                                        input logic [12:0] imm);
    return {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'h63};
  endfunction
  function automatic logic [31:0] enc_j(input logic [4:0] rd, input logic [20:0] imm);
    return {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'h6f};
  endfunction

  /* verilator lint_on UNUSEDSIGNAL */

  logic [1:0]  q;
  logic [2:0]  f3;
  logic [4:0]  rd_f, rs2_f, rdp, rs1p;
  logic [5:0]  imm6u;
  logic [11:0] imm6;       // sign-extended to 12 bits
  logic [11:0] jo;         // c.j / c.jal offset (sign-extended 12 -> 21 below)
  logic [8:0]  bo;         // c.beqz / c.bnez offset
  logic        h12;
  logic [1:0]  f2;
  logic [1:0]  f;

  always_comb begin
    q     = h[1:0];
    f3    = h[15:13];
    rd_f  = h[11:7];
    rs2_f = h[6:2];
    rdp   = {2'b01, h[4:2]};
    rs1p  = {2'b01, h[9:7]};
    h12   = h[12];
    imm6u = {h[12], h[6:2]};
    imm6  = {{6{h[12]}}, h[12], h[6:2]};
    jo    = {h[12], h[8], h[10:9], h[6], h[7], h[2], h[11], h[5:3], 1'b0};
    bo    = {h[12], h[6:5], h[2], h[11:10], h[4:3], 1'b0};
    f2    = h[11:10];
    f     = h[6:5];
    inst  = 32'h0;
    case (q)
      2'd0: begin
        case (f3)
          3'd0: if (h[12:5] != 8'd0) inst = enc_i(OPIMM, rdp, 3'd0, 5'd2, {2'b0, h[10:7], h[12:11], h[5], h[6], 2'b0});
          3'd1: if (FPEN) inst = enc_i(LOADFP, rdp, 3'd3, rs1p, {4'b0, h[6:5], h[12:10], 3'b0});
          3'd2: inst = enc_i(LOAD, rdp, 3'd2, rs1p, {5'b0, h[5], h[12:10], h[6], 2'b0});
          3'd3: begin
            if (RV64) inst = enc_i(LOAD, rdp, 3'd3, rs1p, {4'b0, h[6:5], h[12:10], 3'b0});
            else if (FPEN) inst = enc_i(LOADFP, rdp, 3'd2, rs1p, {5'b0, h[5], h[12:10], h[6], 2'b0});
          end
          3'd5: if (FPEN) inst = enc_s(STOREFP, 3'd3, rs1p, rdp, {4'b0, h[6:5], h[12:10], 3'b0});
          3'd6: inst = enc_s(STORE, 3'd2, rs1p, rdp, {5'b0, h[5], h[12:10], h[6], 2'b0});
          3'd7: begin
            if (RV64) inst = enc_s(STORE, 3'd3, rs1p, rdp, {4'b0, h[6:5], h[12:10], 3'b0});
            else if (FPEN) inst = enc_s(STOREFP, 3'd2, rs1p, rdp, {5'b0, h[5], h[12:10], h[6], 2'b0});
          end
          default: inst = 32'h0;   // 100: reserved
        endcase
      end
      2'd1: begin
        case (f3)
          3'd0: inst = enc_i(OPIMM, rd_f, 3'd0, rd_f, imm6);
          3'd1: begin
            if (RV64) begin
              if (rd_f != 5'd0) inst = enc_i(OPIMMW, rd_f, 3'd0, rd_f, imm6);
            end else begin
              inst = enc_j(5'd1, {{9{jo[11]}}, jo});
            end
          end
          3'd2: inst = enc_i(OPIMM, rd_f, 3'd0, 5'd0, imm6);
          3'd3: begin
            if (rd_f == 5'd2) begin   // c.addi16sp
              if ({h12, h[6:2]} != 6'd0)
                inst = enc_i(OPIMM, 5'd2, 3'd0, 5'd2, {{2{h12}}, h12, h[4:3], h[5], h[2], h[6], 4'b0});
            end else begin            // c.lui
              if (imm6u != 6'd0) inst = {{14{h12}}, h12, h[6:2], rd_f, 7'h37};
            end
          end
          3'd4: begin
            if (f2 == 2'd0 || f2 == 2'd1) begin   // c.srli / c.srai
              if (RV64 || !h12)
                inst = enc_i(OPIMM, rs1p, 3'd5, rs1p, {1'b0, f2 == 2'd1, 4'b0, imm6u});
            end else if (f2 == 2'd2) begin        // c.andi
              inst = enc_i(OPIMM, rs1p, 3'd7, rs1p, imm6);
            end else begin
              if (!h12) begin                     // c.sub / c.xor / c.or / c.and
                case (f)
                  2'd0: inst = enc_r(OP, rs1p, 3'd0, rs1p, rdp, 7'h20);
                  2'd1: inst = enc_r(OP, rs1p, 3'd4, rs1p, rdp, 7'h00);
                  2'd2: inst = enc_r(OP, rs1p, 3'd6, rs1p, rdp, 7'h00);
                  default: inst = enc_r(OP, rs1p, 3'd7, rs1p, rdp, 7'h00);
                endcase
              end else if (RV64 && !f[1]) begin   // c.subw / c.addw
                inst = enc_r(OPW, rs1p, 3'd0, rs1p, rdp, f[0] ? 7'h00 : 7'h20);
              end
            end
          end
          3'd5: inst = enc_j(5'd0, {{9{jo[11]}}, jo});
          default: inst = enc_b(f3[0] ? 3'd1 : 3'd0, rs1p, 5'd0, {{4{bo[8]}}, bo});
        endcase
      end
      2'd2: begin
        case (f3)
          3'd0: if (RV64 || !h12) inst = enc_i(OPIMM, rd_f, 3'd1, rd_f, {6'b0, imm6u});
          3'd1: if (FPEN) inst = enc_i(LOADFP, rd_f, 3'd3, 5'd2, {3'b0, h[4:2], h12, h[6:5], 3'b0});
          3'd2: if (rd_f != 5'd0) inst = enc_i(LOAD, rd_f, 3'd2, 5'd2, {4'b0, h[3:2], h12, h[6:4], 2'b0});
          3'd3: begin
            if (RV64) begin
              if (rd_f != 5'd0) inst = enc_i(LOAD, rd_f, 3'd3, 5'd2, {3'b0, h[4:2], h12, h[6:5], 3'b0});
            end else if (FPEN) begin
              inst = enc_i(LOADFP, rd_f, 3'd2, 5'd2, {4'b0, h[3:2], h12, h[6:4], 2'b0});
            end
          end
          3'd4: begin
            if (!h12) begin
              if (rs2_f == 5'd0) begin
                if (rd_f != 5'd0) inst = enc_i(7'h67, 5'd0, 3'd0, rd_f, 12'd0);   // c.jr
              end else begin
                inst = enc_r(OP, rd_f, 3'd0, 5'd0, rs2_f, 7'h00);                  // c.mv
              end
            end else if (rs2_f == 5'd0) begin
              if (rd_f == 5'd0) inst = 32'h0010_0073;                              // c.ebreak
              else              inst = enc_i(7'h67, 5'd1, 3'd0, rd_f, 12'd0);      // c.jalr
            end else begin
              inst = enc_r(OP, rd_f, 3'd0, rd_f, rs2_f, 7'h00);                    // c.add
            end
          end
          3'd5: if (FPEN) inst = enc_s(STOREFP, 3'd3, 5'd2, rs2_f, {3'b0, h[9:7], h[12:10], 3'b0});
          3'd6: inst = enc_s(STORE, 3'd2, 5'd2, rs2_f, {4'b0, h[8:7], h[12:9], 2'b0});
          default: begin
            if (RV64) inst = enc_s(STORE, 3'd3, 5'd2, rs2_f, {3'b0, h[9:7], h[12:10], 3'b0});
            else if (FPEN) inst = enc_s(STOREFP, 3'd2, 5'd2, rs2_f, {4'b0, h[8:7], h[12:9], 2'b0});
          end
        endcase
      end
      default: inst = 32'h0;   // quadrant 3 is a 32-bit instruction: not expanded here
    endcase
  end

endmodule

`default_nettype wire
