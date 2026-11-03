// Streaming stores over 4x the L1D with one store per line: every miss evicts a dirty line -> WriteBuffer pressure (WB full, stalled fills).
#include "trap.h"
#include <stdint.h>

#define LINES (1u << 15)           // 2 MiB
static volatile uint32_t buf[LINES * 16];

int main() {
  for (uint32_t r = 0; r < 3; r++)
    for (uint32_t i = 0; i < LINES; i++) buf[i * 16 + (r & 15)] = i + r;
  uint32_t sum = 0;
  for (uint32_t i = 0; i < LINES; i += 7) sum += buf[i * 16];
  check(sum != 0);
  return 0;
}
