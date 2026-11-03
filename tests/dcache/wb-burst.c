// Dirty the whole L1D, then read a different region with independent loads (8 outstanding misses): the fills return in a burst,
// each evicting a dirty line -> WriteBuffer fills up faster than its single outstanding AXI write drains (WB full, stalled fills).
#include "trap.h"
#include <stdint.h>

#define LINES 2048u                 // 128 KiB per region (L1D = 64 KiB)
static volatile uint32_t wr[LINES * 16];
static volatile uint32_t rd[LINES * 16];

int main() {
  uint32_t sum = 0;
  for (uint32_t r = 0; r < 4; r++) {
    for (uint32_t i = 0; i < LINES; i++) wr[i * 16 + (i & 15)] = i ^ r;     // dirty lines
    for (uint32_t i = 0; i < LINES; i += 4) {                              // independent loads, 4 lines per iteration
      sum += rd[i * 16] + rd[(i + 1) * 16] + rd[(i + 2) * 16] + rd[(i + 3) * 16];
    }
  }
  check(sum == 0);
  return 0;
}
