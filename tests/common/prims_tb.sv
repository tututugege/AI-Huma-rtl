// Ref: (testbench) exhaustive check of rtl/common primitives
`default_nettype none
module prims_tb;
  localparam int N = 6;
  logic [N-1:0] req, oh;
  logic any;
  logic [2:0] idx;
  logic [3:0] pc;
  logic [7:0] data [N];
  logic [7:0] mout;
  ttg_first_set #(.N(N)) u_fs (.req(req), .onehot(oh), .any(any));
  ttg_onehot_to_idx #(.N(N)) u_ix (.onehot(oh), .idx(idx[2:0]));
  ttg_popcount #(.N(N), .CW(4)) u_pc (.bits(req), .count(pc));
  ttg_onehot_mux #(.N(N), .W(8)) u_mx (.sel(oh), .data(data), .out(mout));
  int errors = 0;
  initial begin
    for (int i = 0; i < N; i++) data[i] = 8'(i * 17 + 3);
    for (int v = 0; v < (1 << N); v++) begin
      req = N'(v);
      #1;
      begin
        int exp_idx; int exp_pc; bit found;
        exp_idx = 0; exp_pc = 0; found = 0;
        for (int i = 0; i < N; i++) begin
          if (req[i]) exp_pc++;
          if (req[i] && !found) begin found = 1; exp_idx = i; end
        end
        if (any !== found) errors++;
        if (found && (oh !== N'(1 << exp_idx) || idx !== 3'(exp_idx) || mout !== data[exp_idx])) errors++;
        if (!found && (oh !== '0 || mout !== '0)) errors++;
        if (pc !== 4'(exp_pc)) errors++;
      end
    end
    if (errors == 0) $display("PRIMS PASS"); else $display("PRIMS FAIL errors=%0d", errors);
    $finish;
  end
endmodule
`default_nettype wire
