// Equivalence test of isu_iq_select against a reference copy (isu_iq_select_ref: the version before the per-port
// generate-signal rewrite), for every issue queue's parameters as isu.sv uses them. Random ready / port_ok / age
// matrix every cycle (a 64-bit xorshift per word); prints the first mismatch or PASS with the vector count.
`default_nettype none
module eq_top import ttg_cfg_pkg::*; import isu_pkg::*; #(parameter int NVEC = 2000000) ();
  logic clk = 1'b0;
  longint unsigned rs = 64'h9e3779b97f4a7c15;
  function automatic longint unsigned rnd();
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    return rs;
  endfunction
  int nvec = 0, nerr = 0;
  longint unsigned nsel = 0;

  for (genvar q = 0; q < IQ_NUM; q++) begin : g_q
    localparam int SIZE = iq_size(q);
    localparam int NP   = iq_port_num(q);
    localparam bit AGE  = (q == IQ_MEM);
    logic [SIZE-1:0] ready, older [SIZE], port_ok [NP];
    logic [SIZE-1:0] oh_a [NP], oh_b [NP];
    logic [NP-1:0]   v_a, v_b;
    isu_iq_select     #(.SIZE(SIZE), .NP(NP), .QID(q), .AGE_EN(AGE)) u_new (.ready, .older, .port_ok, .sel_onehot(oh_a), .sel_valid(v_a));
    isu_iq_select_ref #(.SIZE(SIZE), .NP(NP), .QID(q), .AGE_EN(AGE)) u_ref (.ready, .older, .port_ok, .sel_onehot(oh_b), .sel_valid(v_b));
    always @(posedge clk) begin
      longint unsigned dm;
      dm = rnd();
      ready <= SIZE'(rnd() & (dm[0] ? rnd() : ~64'd0));          // dense or sparse
      for (int p = 0; p < NP; p++) port_ok[p] <= SIZE'(rnd() | (dm[1] ? rnd() : 64'd0));
      // age matrix: a random total order (older[i][j] = j older than i)
      for (int i = 0; i < SIZE; i++) older[i] <= '0;
      for (int i = 0; i < SIZE; i++) for (int j = 0; j < SIZE; j++)
        if (i != j && ((i + j + int'(dm[7:2])) % 2 == 0 ? (j < i) : (j > i))) older[i][j] <= 1'b1;
    end
    always @(negedge clk) begin
      if (nvec > 0) begin
        if (v_a != v_b) begin nerr++; if (nerr < 5) $display("MISMATCH q=%0d valid new=%b ref=%b", q, v_a, v_b); end
        for (int p = 0; p < NP; p++) begin
          if (oh_a[p] != oh_b[p]) begin nerr++; if (nerr < 5) $display("MISMATCH q=%0d port %0d", q, p); end
          nsel += longint'($countones(oh_a[p]));
        end
      end
    end
  end

  initial begin
    for (int k = 0; k <= NVEC; k++) begin
      #1 clk = 1'b1;
      #1 clk = 1'b0;
      nvec = k;
    end
    if (nerr == 0) $display("isu_iq_select PASS: %0d vectors x %0d queues, %0d selections", NVEC, IQ_NUM, nsel);
    else $display("isu_iq_select FAIL: %0d mismatches", nerr);
    $finish;
  end
endmodule
`default_nettype wire
