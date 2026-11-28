// Cleanup F equivalence (items 3, 4): rvc_expand without the rv32 branches against the old one (all 65,536 halfwords),
// and the single branch decoder (predecode_lane: BR_* kind + target) against the three old decoders: predecode_lane
// (2-bit type + target, valid lane), front_slot_kind (3-bit kind) and the call / return test of front_pd_info
// (type == JAL && rd == ra -> push, type == JALR && jalr x0,ra,0 -> pop).  Words: every expanded halfword, then NCYC
// random 32-bit words biased to jal / jalr / branch with rd, rs1 in {x0, ra} and imm 0.
`default_nettype none
module eq_decode import ttg_cfg_pkg::*; import front_pkg::*; import bpu_pkg::*; #(parameter int NCYC = 1000000) ();
  longint unsigned rs = 64'h9e3779b97f4a7c15;
  function automatic longint unsigned rnd();
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return rs;
  endfunction

  logic [15:0]          h;
  logic [31:0]          ex_o, ex_n, w;
  logic [XLEN_BITS-1:0] pc;
  logic [1:0]           o_ty;
  logic [XLEN_BITS-1:0] o_tgt, n_tgt;
  logic [KIND_W-1:0]    o_kind, n_kind;

  rvc_expand_ref     u_exp_o (.h, .inst(ex_o));
  rvc_expand         u_exp_n (.h, .inst(ex_n));
  predecode_lane_ref u_pd_o  (.pc, .inst(w), .inst_valid(1'b1), .predecode_type(o_ty), .predecode_target_address(o_tgt));
  front_slot_kind_ref u_k_o  (.inst(w), .kind(o_kind));
  predecode_lane     u_pd_n  (.pc, .inst(w), .kind(n_kind), .target(n_tgt));

  int nerr = 0, nvec = 0;
  int ncnt [8];
  task automatic check(input string what);
    logic [1:0] o_rop, n_rop;
    #1;
    nvec++;
    o_rop = ((o_ty == PREDECODE_JAL) && (w[11:7] == 5'd1)) ? 2'd1 :
            ((o_ty == PREDECODE_JALR) && (w[11:7] == 5'd0) && (w[19:15] == 5'd1) && (w[31:20] == 12'd0)) ? 2'd2 : 2'd0;
    n_rop = (n_kind == BR_CALL) ? 2'd1 : (n_kind == BR_RET) ? 2'd2 : 2'd0;
    ncnt[n_kind]++;
    if (o_ty !== ptype_of_kind(n_kind) || o_tgt !== n_tgt || o_kind !== n_kind || o_rop !== n_rop) begin
      nerr++;
      if (nerr <= 10) $display("%s word %h pc %h: old type %0d tgt %h kind %0d rop %0d / new kind %0d tgt %h rop %0d",
                               what, w, pc, o_ty, o_tgt, o_kind, o_rop, n_kind, n_tgt, n_rop);
    end
  endtask

  initial begin
    for (int i = 0; i < 65536; i++) begin
      h  = 16'(i);
      pc = rnd();
      w  = 32'h0;
      #1;
      if (ex_o !== ex_n) begin
        nerr++;
        if (nerr <= 10) $display("rvc_expand %h: old %h new %h", h, ex_o, ex_n);
      end
      w = ex_n;
      check("rvc");
    end
    for (int c = 0; c < NCYC; c++) begin
      longint unsigned r;
      r  = rnd();
      w  = 32'(rnd());
      pc = rnd();
      case (r % 8)
        0: w[6:0] = OPCODE_JAL;
        1: w[6:0] = OPCODE_JALR;
        2: w[6:0] = OPCODE_BRANCH;
        3: begin w[6:0] = OPCODE_JALR; w[31:20] = 12'd0; w[19:15] = (r[8]) ? 5'd1 : w[19:15]; end
        default: ;
      endcase
      if (r[9])  w[11:7]  = r[10] ? 5'd1 : 5'd0;
      if (r[11]) w[19:15] = r[12] ? 5'd1 : 5'd0;
      if (r[13]) w[31:20] = 12'd0;
      else if (r[14]) w[31:20] = 12'd1 << ((r >> 20) % 12);   // one immediate bit away from a return
      if (r[15]) w[19:15] = 5'd1 << ((r >> 24) % 5);          // one register bit away from ra
      check("rand");
    end
    $display("kinds: direct %0d call %0d ret %0d idirect %0d nonctl %0d jal %0d icall %0d",
             ncnt[BR_DIRECT], ncnt[BR_CALL], ncnt[BR_RET], ncnt[BR_IDIRECT], ncnt[BR_NONCTL], ncnt[BR_JAL], ncnt[BR_ICALL]);
    if (nerr == 0) $display("PASS eq_decode: 65536 halfwords expanded, %0d decodes, 0 mismatches", nvec);
    else           $display("FAIL eq_decode: %0d mismatches", nerr);
    $finish;
  end
endmodule
`default_nettype wire
