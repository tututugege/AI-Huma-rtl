#include "Vidu_ctrl_decode.h"
#include <cstdio>
#include <cstdint>
int main(){ Vidu_ctrl_decode d; unsigned x;
  while (scanf("%x",&x)==1){ d.inst=x; d.eval();
    printf("%08x type=%d dest=%d s1=%d s2=%d s2imm=%d f3=%d da=%d s1a=%d s2a=%d ill=%d dfp=%d s1fp=%d s2fp=%d s3=%d s3a=%d cls=%d\n",x,d.uop_type,d.dest_en,d.src1_en,d.src2_en,d.src2_is_imm,d.func3,d.dest_areg,d.src1_areg,d.src2_areg,d.illegal_inst,d.dest_fp,d.src1_fp,d.src2_fp,d.src3_en,d.src3_areg,d.fp_cls);} }
