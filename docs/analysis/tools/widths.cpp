#include "front_IO.h"
#include "front_module.h"
#include <cstdio>
int main(){
#define P(x) std::printf("%-28s %d\n", #x, (int)(x))
 P(FETCH_WIDTH);P(BACKEND_FETCH_WIDTH);P(COMMIT_WIDTH);P(TN_MAX);P(BPU_SCL_META_NTABLE);P(pcpn_t_BITS);P(tage_idx_t_BITS);P(tage_tag_t_BITS);
 P(tage_scl_meta_idx_t_BITS);P(tage_scl_meta_sum_t_BITS);P(tage_loop_meta_idx_t_BITS);P(tage_loop_meta_tag_t_BITS);
 P(INSTRUCTION_FIFO_SIZE);P(PTAB_SIZE);P(FETCH_ADDR_FIFO_SIZE);P(FRONT2BACK_FIFO_SIZE);
 P(fetch_addr_fifo_size_t_BITS);P(instruction_fifo_size_t_BITS);P(ptab_size_t_BITS);P(front2back_fifo_size_t_BITS);
 int ptab_bits = FETCH_WIDTH*(1+32+1+3+3+TN_MAX*(tage_idx_t_BITS+tage_tag_t_BITS)+1+1+16+BPU_SCL_META_NTABLE*tage_scl_meta_idx_t_BITS+1+1+1+tage_loop_meta_idx_t_BITS+tage_loop_meta_tag_t_BITS)+32+2;
 P(ptab_bits);
 int f2b_bits = FETCH_WIDTH*(32+1+1+1+32+1+3+3+TN_MAX*(tage_idx_t_BITS+tage_tag_t_BITS)+1+1+16+BPU_SCL_META_NTABLE*tage_scl_meta_idx_t_BITS+1+1+1+tage_loop_meta_idx_t_BITS+tage_loop_meta_tag_t_BITS)+32;
 P(f2b_bits);
 int inst_bits = FETCH_WIDTH*(32+32+1+1+2+32)+32; P(inst_bits);
}
