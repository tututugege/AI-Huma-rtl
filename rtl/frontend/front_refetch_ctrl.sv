// Ref: front-end/front_top.cpp  front_global_control_comb; predecode_refetch / predecode_refetch_address
`default_nettype none

// Global refetch: a backend refetch or the delayed predecode refetch (the checker found a wrong prediction last cycle).
// The backend wins the address select.  The delayed refetch is the only real state of the front-end control: one
// flag plus the corrected fetch address, both loaded at the end of the cycle that decided the flush.
module front_refetch_ctrl (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        be_refetch,
  input  logic [31:0] be_refetch_address,
  input  logic        do_predecode_flush,
  input  logic [31:0] predecode_flush_address,
  output logic        global_refetch,
  output logic [31:0] refetch_address
);

  logic        predecode_refetch_q;
  logic        predecode_refetch_d;
  logic [31:0] predecode_refetch_address_q;
  logic [31:0] predecode_refetch_address_d;

  // Ref: front_global_control_comb
  always_comb begin
    global_refetch  = be_refetch || predecode_refetch_q;
    refetch_address = be_refetch ? be_refetch_address : predecode_refetch_address_q;
  end

  // Ref: front_comb_calc S12 (next_predecode_refetch).  The C++ also zeroes the address when there is no flush; the
  // address is only read while predecode_refetch_q is set (BPU: refetch ? refetch_address : ..., BPU.h:820,1779), so
  // it is simply loaded every cycle.
  always_comb begin
    predecode_refetch_d         = do_predecode_flush;
    predecode_refetch_address_d = predecode_flush_address;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      predecode_refetch_q         <= 1'b0;
      predecode_refetch_address_q <= 32'd0;
    end else begin
      predecode_refetch_q         <= predecode_refetch_d;
      predecode_refetch_address_q <= predecode_refetch_address_d;
    end
  end

endmodule

`default_nettype wire
