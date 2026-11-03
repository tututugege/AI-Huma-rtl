# Toy module that only exists to validate the harness (scalars, arrays, 2-D arrays, wide fields, `when`).
module toy_fifo

in  push_valid 1
in  push_data  8
in  pop_ready  1
in  flush      1
in  blob       80

out push_ready 1
out pop_valid  1
out pop_data   8  when pop_valid
out count      3
out slot_valid 1  [4]
out slot_data  8  [4] when slot_valid
out blob_rot   80
out lane_sum   4  [2][2]
