// Dirty-line streaming (one store per line, as wb-flood) plus a dense fan of extra stores to the lines evicted ~1024+d lines ago: the line
// that was pushed out a few cycles earlier may still be queued in the WriteBuffer, then the store is merged into the WB entry (or finds
// it busy when it is the head being written) and a following load is forwarded from it.
#include "trap.h"
#include <stdint.h>

#define LINES 4096u                 // 256 KiB (L1D holds 1024 lines)
static volatile uint32_t buf[LINES * 16];

int main() {
  uint32_t sum = 0;
  for (uint32_t i = 1200; i < LINES; i++) {
    buf[i * 16 + 1] = i;
    for (uint32_t d = 1024 + 16; d < 1024 + 112; d++) {
      buf[(i - d) * 16 + 2] = i;
      sum += buf[(i - d) * 16 + 3];
    }
  }
  check(sum != 1);
  return 0;
}
