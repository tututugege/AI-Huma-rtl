# fetch_address FIFO (16 x 32b) as a standalone 1R1W FIFO. full = size>=15 (check_fifo_trace.py --cap 16 --full-at 15).
# Naming convention of all FIFO specs (needed by check_fifo_trace.py): reset refetch rd_en wr_en wr_* | rd_valid rd_* full empty
# refetch here = reset|refetch of the C++ FIFO input in the read call (= global_refetch).
module fetch_addr_fifo
in  reset   1 @ TTG_FT.global_reset
in  refetch 1 @ TTG_FT.global_refetch
in  rd_en   1 @ TTG_FT.fetch_addr_fifo_read_enable_slot0
in  wr_en   1 @ TTG_FT.fetch_addr_req.push_en
in  wr_fetch_address 32 @ TTG_FT.fetch_addr_req.push_data
out rd_valid 1 @ TTG_FT.fetch_addr_req.pop_en
out rd_fetch_address 32 when rd_valid @ TTG_FT.fa_out0.fetch_address
out full  1 @ TTG_FT.full_q[0]
out empty 1 @ TTG_FT.empty_q[0]
