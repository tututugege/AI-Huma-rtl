# (name, file, ctx, old, new)  -- see scripts/mut_memcpu.py
A = 'rtl/memsys/axi_cpu_port_adapter/'
MUTANTS = [
    ('ready_not_ored', A + 'axi_cpu_port_chan.sv', "ready_acc_n   = phase0 ? raw_ready    : (ready_acc_q || raw_ready);", "(ready_acc_q || raw_ready)", "raw_ready"),
    ('ready_not_reset_each_cycle', A + 'axi_cpu_port_chan.sv', "ready_acc_n   = phase0 ? raw_ready    : (ready_acc_q || raw_ready);", "phase0", "1'b0"),
    ('accepted_not_sticky', A + 'axi_cpu_port_chan.sv', "acc_n         = phase0 ? raw_accepted : (acc_q || raw_accepted);", "(acc_q || raw_accepted)", "raw_accepted"),
    ('accepted_not_reset_each_cycle', A + 'axi_cpu_port_chan.sv', "acc_n         = phase0 ? raw_accepted : (acc_q || raw_accepted);", "phase0", "1'b0"),
    ('acc_id_never_updated', A + 'axi_cpu_port_chan.sv', "acc_id_n      = raw_accepted ? raw_accepted_id : acc_id_q;", "raw_accepted", "1'b0"),
    ('acc_id_first_accept_wins', A + 'axi_cpu_port_chan.sv', "acc_id_n      = raw_accepted ? raw_accepted_id : acc_id_q;", "raw_accepted", "(raw_accepted && (phase0 || !acc_q))"),
    ('hide_without_id_compare', A + 'axi_cpu_port_chan.sv', "wire hide_resp    = acc_n && raw_resp_valid && (raw_resp_id == acc_id_n);", "(raw_resp_id == acc_id_n)", "1'b1"),
    ('hide_compares_tick0_resp_id', A + 'axi_cpu_port_chan.sv', "wire hide_resp    = acc_n && raw_resp_valid && (raw_resp_id == acc_id_n);", "(raw_resp_id == acc_id_n)", "(raw_resp_id == resp0_id_n)"),
    ('hide_needs_no_accept', A + 'axi_cpu_port_chan.sv', "wire hide_resp    = acc_n && raw_resp_valid && (raw_resp_id == acc_id_n);", "acc_n", "1'b1"),
    ('resp_valid_never_hidden', A + 'axi_cpu_port_chan.sv', "view_resp_valid_n = raw_resp_valid && !hide_resp;", "!hide_resp", "1'b1"),
    ('resp_new_ignores_id', A + 'axi_cpu_port_chan.sv', "wire resp_is_new  = raw_resp_valid && !(resp0_valid_n && (resp0_id_n == raw_resp_id));", "(resp0_valid_n && (resp0_id_n == raw_resp_id))", "resp0_valid_n"),
    ('resp_ready_not_withheld_new', A + 'axi_cpu_port_chan.sv', "view_resp_ready_n = resp0_ready_n && !(resp_is_new || hide_resp);", "(resp_is_new || hide_resp)", "hide_resp"),
    ('resp_ready_not_withheld_hidden', A + 'axi_cpu_port_chan.sv', "view_resp_ready_n = resp0_ready_n && !(resp_is_new || hide_resp);", "(resp_is_new || hide_resp)", "resp_is_new"),
    ('resp_ready_last_tick', A + 'axi_cpu_port_chan.sv', "resp0_ready_n = phase0 ? raw_resp_ready : resp0_ready_q;", "phase0 ? raw_resp_ready : resp0_ready_q", "raw_resp_ready"),
    ('resp0_valid_last_tick', A + 'axi_cpu_port_chan.sv', "resp0_valid_n = phase0 ? raw_resp_valid : resp0_valid_q;", "phase0 ? raw_resp_valid : resp0_valid_q", "raw_resp_valid"),
    ('view_resp_id_tick0', A + 'axi_cpu_port_chan.sv', "view_resp_id_q     <= raw_resp_id;", "raw_resp_id", "resp0_id_n"),
    ('view_updated_every_tick', A + 'axi_cpu_port_chan.sv', "if (phase_last) begin", "phase_last", "1'b1"),
    ('view_updated_at_tick0', A + 'axi_cpu_port_chan.sv', "if (phase_last) begin", "phase_last", "phase0"),
    ('write_id_exported', A + 'axi_cpu_port_chan.sv', "view_accepted_id_q <= EXPORT_ID ? acc_id_n : '0;", "EXPORT_ID", "1'b1"),
    ('channels_crossed', A + 'axi_cpu_port_adapter.sv', ".raw_accepted     (raw_accepted[c]),", "raw_accepted[c]", "raw_accepted[(c + 1) % AX_NCH]"),
]
