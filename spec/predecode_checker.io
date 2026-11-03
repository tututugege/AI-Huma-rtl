# predecode_checker: pure combinational (predecode_checker.cpp). Recorded every cycle; when the checker does not run
# (predecode_can_run=0) the tap holds all-zero inputs and the all-zero outputs the function gives for them.
module predecode_checker
in  predict_dir 1 [8] @ TTG_FT.checker_in.predict_dir[i0]
in  predict_next_fetch_address 32 @ TTG_FT.checker_in.predict_next_fetch_address
in  predecode_type 2 [8] @ TTG_FT.checker_in.predecode_type[i0]
in  predecode_target_address 32 [8] @ TTG_FT.checker_in.predecode_target_address[i0]
in  seq_next_pc 32 @ TTG_FT.checker_in.seq_next_pc
out predict_dir_corrected 1 [8] @ TTG_FT.checker_out.predict_dir_corrected[i0]
out predict_next_fetch_address_corrected 32 @ TTG_FT.checker_out.predict_next_fetch_address_corrected
out predecode_flush_enable 1 @ TTG_FT.checker_out.predecode_flush_enable
