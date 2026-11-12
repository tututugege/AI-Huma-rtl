// Ref: back-end/Dispatch.cpp  Dispatch::is_preg_woken / apply_wakeup_to_uop
`default_nettype none

// CAM of source physical registers against all wakeup ports (4 load-writeback + 15 issue wakeups).
module dispatch_wake_match
  import ttg_cfg_pkg::*;
  import dis_pkg::*;
#(
  parameter int NSRC = 3 * NUM_SLOTS
) (
  input  logic [NUM_WAKE-1:0] wake_valid,
  input  logic [PRF_IDX_WIDTH-1:0]  wake_preg  [NUM_WAKE],
  input  logic [PRF_IDX_WIDTH-1:0]  src_preg   [NSRC],
  output logic                      woken      [NSRC]
);

  // Ref: Dispatch::is_preg_woken (any valid wakeup port carrying this preg)
  always_comb begin
    for (int s = 0; s < NSRC; s++) begin
      woken[s] = 1'b0;
      for (int w = 0; w < NUM_WAKE; w++) begin
        woken[s] = woken[s] || (wake_valid[w] && (wake_preg[w] == src_preg[s]));
      end
    end
  end

endmodule

`default_nettype wire
