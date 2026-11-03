# fetch_address_FIFO (16 x 32b), standalone 1R1W queue.  One cycle: clear (refetch) -> push (wr_en) -> pop (rd_valid);
# rd_valid = rd_en & ~refetch & size>0 (reads the head from BEFORE this cycle's push); full = size>=15, empty = size==0
# of the START of the cycle (front_top.cpp front_state_req.next_*; the C++ latches are pure functions of size).
# C++ global_reset (= front.in.reset) is only 1 inside FrontTop::init(); the RTL rst_n replaces it, so there is no reset port.
# refetch = global_refetch (backend refetch | delayed predecode refetch).
module fetch_addr_fifo
in  refetch 1 @ TTG_FT.global_refetch
in  rd_en   1 @ TTG_FT.fetch_addr_fifo_read_enable_slot0
in  wr_en   1 @ TTG_FT.fetch_addr_req.push_en
in  wr_fetch_address 32 @ TTG_FT.fetch_addr_req.push_data
out rd_valid 1 @ TTG_FT.fetch_addr_req.pop_en
out rd_fetch_address 32 when rd_valid @ TTG_FT.fa_out0.fetch_address
out full  1 @ TTG_FT.full_q[0]
out empty 1 @ TTG_FT.empty_q[0]
