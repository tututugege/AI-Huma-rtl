# sequential_next_pc: front_top.cpp:78-96 (CONFIG_FRONT_VALID_PREFIX_SEQ_NEXT = 1). Recorded where the instruction FIFO
# entry is pushed (inst_req.push_en); in the other cycles the inputs are 0 and the function gives 0 (fetch_pc=0, no valid lane).
module sequential_next_pc
in  fetch_pc   32 @ TTG_FT.inst_req.push_en ? TTG_FT.icache_out.fetch_pc : 0
in  inst_valid 1  [8] @ TTG_FT.inst_req.push_en && TTG_FT.icache_out.inst_valid[i0]
out seq_next_pc 32 @ TTG_FT.inst_req.push_entry.seq_next_pc
