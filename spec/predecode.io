# predecode: 8 lanes of front-end/predecode.cpp predecode_comb() as one combinational block (lane pc = fetch_pc + 4*i).
# Real-program recording: the C++ only predecodes when it pushes an instruction-FIFO entry (inst_req.push_en); in the
# other cycles the inputs are recorded as 0 (inst_valid = 0 -> type NON_BRANCH / target 0, like the zeroed push entry).
# Lanes with inst_valid = 0 are forced to NON_BRANCH/0 here (front_top.cpp:1631-1634), so the invalid-lane `inst` is not read.
module predecode
in  fetch_pc   32 @ TTG_FT.inst_req.push_en ? TTG_FT.icache_out.fetch_pc : 0
in  inst       32 [8] @ TTG_FT.inst_req.push_en ? TTG_FT.icache_out.fetch_group[i0] : 0
in  inst_valid 1  [8] @ TTG_FT.inst_req.push_en && TTG_FT.icache_out.inst_valid[i0]
out predecode_type           2  [8] @ TTG_FT.inst_req.push_entry.predecode_type[i0]
out predecode_target_address 32 [8] @ TTG_FT.inst_req.push_entry.predecode_target_address[i0]
