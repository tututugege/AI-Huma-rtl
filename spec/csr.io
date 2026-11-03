# Csr (back-end/Exu/Csr.cpp): CSR register file, privilege, trap/xRET, interrupt pending/delegation. Boundary = Csr::comb_* wires.
# Not translated: debug_ptw_trace hook (satp write record), rob_bcast fields Csr never reads (flush/exception/fence/head_*), exe2csr/csr read of unknown CSR numbers (C++ aborts).
# Qualifier outputs (*_vld) exist only because `when` must name an output: they gate outputs whose C++ value is a held/stale
# member when not consumed (see docs/modules/csr.md section 4).
module csr

# ---- inputs ----
in  exe2csr_we 1 @ bt.exe2csr.we
in  exe2csr_re 1 @ bt.exe2csr.re
in  exe2csr_idx 12 @ bt.exe2csr.idx
in  exe2csr_wdata 32 @ bt.exe2csr.wdata
in  exe2csr_wcmd 2 @ bt.exe2csr.wcmd
in  rob_bcast_mret 1 @ bt.rob_bcast.mret
in  rob_bcast_sret 1 @ bt.rob_bcast.sret
in  rob_bcast_ecall 1 @ bt.rob_bcast.ecall
in  rob_bcast_page_fault_inst 1 @ bt.rob_bcast.page_fault_inst
in  rob_bcast_page_fault_load 1 @ bt.rob_bcast.page_fault_load
in  rob_bcast_page_fault_store 1 @ bt.rob_bcast.page_fault_store
in  rob_bcast_illegal_inst 1 @ bt.rob_bcast.illegal_inst
in  rob_bcast_trap_val 32 @ bt.rob_bcast.trap_val
in  rob_bcast_pc 32 @ bt.rob_bcast.pc
in  rob2csr_interrupt_resp 1 @ bt.rob2csr.interrupt_resp
in  rob2csr_commit 1 @ bt.rob2csr.commit
in  interrupt_inject_external_irq_pending_valid 1 @ bt.csr_interrupt_inject_io.external_irq_pending_valid
in  interrupt_inject_external_irq_pending 1 @ bt.csr_interrupt_inject_io.external_irq_pending
in  interrupt_inject_supervisor_external_irq_pending_valid 1 @ bt.csr_interrupt_inject_io.supervisor_external_irq_pending_valid
in  interrupt_inject_supervisor_external_irq_pending 1 @ bt.csr_interrupt_inject_io.supervisor_external_irq_pending
in  interrupt_inject_timer_irq_pending_valid 1 @ bt.csr_interrupt_inject_io.timer_irq_pending_valid
in  interrupt_inject_timer_irq_pending 1 @ bt.csr_interrupt_inject_io.timer_irq_pending

# ---- outputs ----
out csr2exe_rdata_vld 1 @ bt.exe2csr.re
out csr2exe_rdata 32 when csr2exe_rdata_vld @ bt.csr2exe.rdata
out csr2rob_interrupt_req 1 @ bt.csr2rob.interrupt_req
out csr2front_epc_vld 1 @ (bt.rob_bcast.mret || bt.rob_bcast.sret)
out csr2front_epc 32 when csr2front_epc_vld @ bt.csr2front.epc
out csr2front_trap_pc_vld 1 @ bt.rob_bcast.exception
out csr2front_trap_pc 32 when csr2front_trap_pc_vld @ bt.csr2front.trap_pc
out csr_status_sstatus 32 @ bt.csr_status.sstatus
out csr_status_mstatus 32 @ bt.csr_status.mstatus
out csr_status_satp 32 @ bt.csr_status.satp
out csr_status_privilege 2 @ bt.csr_status.privilege
