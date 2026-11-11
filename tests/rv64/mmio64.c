// rv64: 8-byte accesses (ld / sd) to the memory-mapped timer: mtimecmp round trip, 64-bit mtime read, and lw / lwu / lh views of the same words
#include "trap.h"
#include <stdint.h>

#define TIMER_LOW 0x1fd0e000ull
#define TIMER_CMP 0x1fd0e008ull

static inline uint64_t ld64(uint64_t addr) { uint64_t v; asm volatile("ld %0, 0(%1)" : "=r"(v) : "r"(addr) : "memory"); return v; }
static inline void sd64(uint64_t addr, uint64_t v) { asm volatile("sd %0, 0(%1)" : : "r"(v), "r"(addr) : "memory"); }
static inline int64_t lw32(uint64_t addr) { int64_t v; asm volatile("lw %0, 0(%1)" : "=r"(v) : "r"(addr) : "memory"); return v; }
static inline uint64_t lwu32(uint64_t addr) { uint64_t v; asm volatile("lwu %0, 0(%1)" : "=r"(v) : "r"(addr) : "memory"); return v; }

int main() {
  const uint64_t big = 0x7ffff11223344556ull;     // far in the future: no timer interrupt
  sd64(TIMER_CMP, big);
  check(ld64(TIMER_CMP) == big);
  check(lwu32(TIMER_CMP) == 0x23344556ull);
  check(lw32(TIMER_CMP + 4) == 0x7ffff112ll);
  sd64(TIMER_CMP, 0x7ff00000ffffffffull);   // bit 31 of the low word set: lw sign-extends, lwu does not
  check(lw32(TIMER_CMP) == -1ll);
  check(lwu32(TIMER_CMP) == 0xffffffffull);
  check(ld64(TIMER_CMP) == 0x7ff00000ffffffffull);
  const uint64_t t0 = ld64(TIMER_LOW);
  volatile int spin = 0;
  for (int i = 0; i < 200; i++) spin += i;
  const uint64_t t1 = ld64(TIMER_LOW);
  check(t1 >= t0);
  check((t1 >> 32) == (t0 >> 32) || (t1 >> 32) == (t0 >> 32) + 1);
  sd64(TIMER_CMP, ~0ull);                          // park the comparator
  return 0;
}
