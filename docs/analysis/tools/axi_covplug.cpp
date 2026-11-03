#include <cstdint>
#include <cstdlib>
class SimCpu;
extern "C" void ttg_rec_cycle(SimCpu *, uint64_t) {}
extern "C" void ttg_rec_finish() { std::exit(0); }
