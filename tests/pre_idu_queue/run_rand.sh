#!/usr/bin/env bash
# Build the random-stimulus generator against the (read-only) reference sources and write traces/pre_idu_queue/rand_*.trc.
#   usage: bash tests/pre_idu_queue/run_rand.sh     (needs build/pre_idu_queue/pre_idu_queue_fields.h, e.g. after scripts/record.sh)
# Built WITHOUT -DNDEBUG on purpose: the reference model's Asserts (commit cursor == ftq_idx, buffer overflow, ...) check the stimulus.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd "$ROOT"
REF=${REFSIM:-/Users/ruyaoh/personal/AI-Huma/rtl/refsim}
INC=()
for d in include libs/include back-end/include back-end/Exu/include back-end/Lsu/include back-end/tools/include MemSubSystem/include diff/include front-end; do INC+=("-I$REF/$d"); done
python3 harness/tools/iogen.py spec/pre_idu_queue.io build/pre_idu_queue >/dev/null
clang++ -std=c++2a -O1 -w "${INC[@]}" -Iharness/include -Ibuild/pre_idu_queue tests/pre_idu_queue/rand_trace.cpp \
  "$REF/back-end/PreIduQueue.cpp" "$REF/back-end/InstructionBuffer.cpp" -o build/pre_idu_queue/rand_trace
mkdir -p traces/pre_idu_queue
G=build/pre_idu_queue/rand_trace; T=traces/pre_idu_queue
#      file                seed cycles p_front p_cons p_commit p_mis p_flush p_sparse
$G $T/rand_a.trc  1  60000 70 60 60 3  1 20
$G $T/rand_b.trc  2  60000 90 25 70 2  0 10   # IBuffer / FTQ full most of the time
$G $T/rand_c.trc  3  60000 50 90 90 6  3 40   # shallow queues, many recoveries and flushes
$G $T/rand_d.trc  4  60000 95 95 30 1  1 5    # FTQ near full (slow commit)
