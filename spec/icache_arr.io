# icache_arr: tag/valid/data arrays + hit/invalid-way decode (GenericTable x3 + lookup meta pack).  Sub-spec of spec/icache.io for bisecting.
# Inputs: the table read request and compare context of the final comb pass, the table write port (step 0: the fetch step).
# hit_line is the line of the hit way (C++ lookup_in.data_resp_line), meaningful on a hit; first_invalid only when has_invalid.
module icache_arr
in  rd_en      1  @ TTG_IC.step[0].rd_en
in  rd_index   6  @ TTG_IC.step[0].rd_index
in  cmp_valid  1  @ TTG_IC.step[0].meta_cmp_valid
in  cmp_tag    20 @ TTG_IC.step[0].meta_cmp_tag
in  we         1  @ TTG_IC.step[0].tw_we
in  w_index    6  @ TTG_IC.step[0].tw_index
in  w_way      3  @ TTG_IC.step[0].tw_way
in  w_tag      20 @ TTG_IC.step[0].tw_tag
in  w_line     512 @w TTG_IC.step[0].tw_data
in  inv_all    1  @ TTG_IC.step[0].tw_inv
out hit        1  @ TTG_IC.step[0].meta_hit_valid
out hit_line   512 when hit @w TTG_IC.step[0].data_line
out has_invalid 1 @ TTG_IC.step[0].meta_has_invalid
out first_invalid 3 when has_invalid @ TTG_IC.step[0].meta_first_invalid
