# End-to-end probe of record -> replay on the real reference simulator: the simulator's cycle counter.
module cyc_probe

in  tick       1  @ 1
out cycle      32 @ cpu.ctx.perf.cycle
out cycle_w    64 @w &cpu.ctx.perf.cycle
