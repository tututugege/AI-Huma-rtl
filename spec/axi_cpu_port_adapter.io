# CPU-boundary adapter of the non-DCache AXI master ports (rv_simu_mmu_v2.cpp: capture/accumulate/restore_axi_cpu_boundary_state + mask_axi_cpu_boundary_for_internal_tick),
# FAST-clock domain: one record per INTERNAL TICK (16 per CPU cycle; the lock-step shell scripts/memcpu_shell.cpp replays the 16 tick records of a cycle).
# Channels: 0 = read ICACHE master, 1 = read EXTRA (peripheral) master, 2 = write EXTRA (peripheral) master.
# raw_* = the interconnect-side values of that tick, sampled where the C++ reads them (docs/analysis/memcpu-record-hook.md): ready = port req.ready (comb), accepted / accepted_id =
# the interconnect's accepted STATE after that tick's seq (write: port req.id), resp_* = port resp.valid/id (comb), resp_ready = the master's resp.ready (only tick 0 is used).
# cpu_* = the CPU view the C++ restores into the ports at the end of tick 15 and the CPU reads from tick 0 of the next cycle on (registered here: constant over the 16 ticks of a cycle).
# The write channel's accepted_id is only used internally (the C++ never restores it): the tap records 0 for channel 2 and the RTL exports 0 there.
module axi_cpu_port_adapter

in  phase0                1  @ TTG_MC.t == 0
in  phase_last            1  @ TTG_MC.t == 15
in  raw_ready             1  [3] @ TTG_MC.pub.ax[TTG_MC.t].ch[i0].ready
in  raw_accepted          1  [3] @ TTG_MC.pub.ax[TTG_MC.t].ch[i0].accepted
in  raw_accepted_id       4  [3] @ TTG_MC.pub.ax[TTG_MC.t].ch[i0].accepted_id & 0xf
in  raw_resp_valid        1  [3] @ TTG_MC.pub.ax[TTG_MC.t].ch[i0].resp_valid
in  raw_resp_id           4  [3] @ TTG_MC.pub.ax[TTG_MC.t].ch[i0].resp_id & 0xf
in  raw_resp_ready        1  [3] @ TTG_MC.pub.ax[TTG_MC.t].ch[i0].resp_ready

out cpu_ready             1  [3] @ TTG_MC.pub.exp_view.ch[i0].ready
out cpu_accepted          1  [3] @ TTG_MC.pub.exp_view.ch[i0].accepted
out cpu_accepted_id       4  [3] when cpu_accepted @ TTG_MC.pub.exp_view.ch[i0].accepted_id & 0xf
out cpu_resp_valid        1  [3] @ TTG_MC.pub.exp_view.ch[i0].resp_valid
out cpu_resp_id           4  [3] when cpu_resp_valid @ TTG_MC.pub.exp_view.ch[i0].resp_id & 0xf
out cpu_resp_ready        1  [3] @ TTG_MC.pub.exp_view.ch[i0].resp_ready
