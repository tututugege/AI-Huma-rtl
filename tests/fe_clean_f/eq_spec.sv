// Cleanup F equivalence (item 4): bpu_spec with the 1-push RAS write overlay (rov_t) against the old 3-slot overlay
// (ref/, slot 1 never written, at most one slot written per path).  Random commit stream / restore commands / issue /
// refetch every cycle for NCYC cycles; the outputs and the whole RAS state (rp_q, st_q, nos_q, aras_q) and the
// histories are compared every cycle.
`default_nettype none
module eq_spec import ttg_cfg_pkg::*; import bpu_pkg::*; import bpu_stage_pkg::*; #(parameter int NCYC = 1000000) ();
  logic clk = 1'b0, rst_n = 1'b0;
  longint unsigned rs = 64'h5851f42d4c957f2d;
  function automatic longint unsigned rnd();
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return rs;
  endfunction
  function automatic logic [1023:0] rbits();
    logic [1023:0] v;
    for (int k = 0; k < 16; k++) v[64 * k +: 64] = rnd();
    return v;
  endfunction
  function automatic logic [1:0] rop();   // mostly push / pop
    longint unsigned r = rnd() % 8;
    return (r < 3) ? 2'd1 : (r < 6) ? 2'd2 : 2'(r);
  endfunction

  logic [NCOMMIT-1:0]   upd_valid, actual_dir, upd_is_rvc;
  logic [XLEN_BITS-1:0] base_pc [NCOMMIT], target [NCOMMIT];
  logic [2:0]           br_type [NCOMMIT];
  logic [1:0]           h_mode, r_mode, r_op, hr_mode, rr_mode, rr_op, g0_r_op;
  hist_ck_t             h_ck, hr_ck;
  ras_ck_t              r_ck, rr_ck;
  logic                 h_push_en, hr_push_n, refetch, issue, g0_h_en;
  logic [HSYM_W-1:0]    h_push_bits, hr_push_bits, g0_h_bits;
  logic [XLEN_BITS-1:0] r_val, rr_val, g0_r_val;
  ck_t                  o_ck, n_ck;
  logic                 o_ne, n_ne;
  logic [XLEN_BITS-1:0] o_top, n_top;
  ex_fh_t               o_fh, n_fh;

  bpu_spec_ref u_o (.clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .upd_is_rvc, .target, .h_mode, .h_ck,
    .h_push_en, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .spec_ck(o_ck), .spec_ras_nonempty(o_ne),
    .spec_ras_top(o_top), .spec_ex_fh(o_fh), .refetch, .issue, .g0_h_en, .g0_h_bits, .g0_r_op, .g0_r_val, .hr_mode,
    .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val);
  bpu_spec     u_n (.clk, .rst_n, .upd_valid, .base_pc, .br_type, .actual_dir, .upd_is_rvc, .target, .h_mode, .h_ck,
    .h_push_en, .h_push_bits, .r_mode, .r_ck, .r_op, .r_val, .spec_ck(n_ck), .spec_ras_nonempty(n_ne),
    .spec_ras_top(n_top), .spec_ex_fh(n_fh), .refetch, .issue, .g0_h_en, .g0_h_bits, .g0_r_op, .g0_r_val, .hr_mode,
    .hr_ck, .hr_push_n, .hr_push_bits, .rr_mode, .rr_ck, .rr_op, .rr_val);

  task automatic drive();
    logic [1023:0] b;
    longint unsigned r = rnd();
    upd_valid  = NCOMMIT'(rnd()); actual_dir = NCOMMIT'(rnd()); upd_is_rvc = NCOMMIT'(rnd());
    for (int i = 0; i < NCOMMIT; i++) begin base_pc[i] = rnd(); target[i] = rnd(); br_type[i] = 3'(rnd() % 7); end
    {h_mode, r_mode, hr_mode, rr_mode} = 8'(rnd());
    r_op = rop(); rr_op = rop(); g0_r_op = rop();
    b = rbits(); h_ck  = hist_ck_t'(b[$bits(hist_ck_t)-1:0]);
    b = rbits(); hr_ck = hist_ck_t'(b[$bits(hist_ck_t)-1:0]);
    b = rbits(); r_ck  = ras_ck_t'(b[$bits(ras_ck_t)-1:0]);
    b = rbits(); rr_ck = ras_ck_t'(b[$bits(ras_ck_t)-1:0]);
    {h_push_en, hr_push_n, g0_h_en} = 3'(r);
    refetch = (r >> 3) % 8 == 0;
    issue   = r[8];
    {h_push_bits, hr_push_bits, g0_h_bits} = 9'(r >> 10);
    r_val = rnd(); rr_val = rnd(); g0_r_val = rnd();
  endtask

  int ncyc = 0, nerr = 0;
  always @(posedge clk) if (rst_n) begin
    ncyc++;
    if ({o_ck, o_ne, o_top, o_fh} !== {n_ck, n_ne, n_top, n_fh} || u_o.rp_q !== u_n.rp_q || u_o.aras_q !== u_n.aras_q ||
        u_o.spec_q !== u_n.spec_q) begin
      nerr++; if (nerr <= 10) $display("cycle %0d: outputs / rp_q / aras_q / spec_q differ", ncyc);
    end
    for (int j = 0; j < RASQ_N; j++)
      if (u_o.st_q[j] !== u_n.st_q[j] || u_o.nos_q[j] !== u_n.nos_q[j]) begin
        nerr++; if (nerr <= 10) $display("cycle %0d: RAS entry %0d differs", ncyc, j);
      end
  end
  initial begin
    drive();
    repeat (3) begin #1 clk = 1'b1; #1 clk = 1'b0; end
    rst_n = 1'b1;
    for (int c = 0; c < NCYC; c++) begin drive(); #1 clk = 1'b1; #1 clk = 1'b0; end
    if (nerr == 0) $display("PASS eq_spec: %0d cycles, 0 mismatches", ncyc);
    else           $display("FAIL eq_spec: %0d mismatches", nerr);
    $finish;
  end
endmodule
`default_nettype wire
