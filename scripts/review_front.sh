#!/usr/bin/env bash
# Coordinator review of the front_basic branch: every module rebuilt with the MAIN harness, replayed on real + generated traces.
W=/Users/ruyaoh/personal/AI-Huma/rtl-wt/front_basic
M=$(cd "$(dirname "$0")/.." && pwd)
run() { echo "##### $1"; bash "$M/scripts/review.sh" "$W" "$@" 2>&1 | tail -6; }
run predecode          dhrystone vm_pagefault_test cjpeg rand_a rand_b
run sequential_next_pc dhrystone vm_pagefault_test rand_a
run predecode_checker  dhrystone vm_pagefault_test rand_a rand_b
run fetch_addr_fifo    dhrystone vm_pagefault_test rand_1 rand_2 rand_3
run inst_fifo          dhrystone vm_pagefault_test rand_1 rand_2 rand_3
run ptab               dhrystone vm_pagefault_test rand_1 rand_2 rand_3
run front2back_fifo    dhrystone vm_pagefault_test rand_1 rand_2 rand_3
run front_ctrl         dhrystone vm_pagefault_test exh_a exh_b
