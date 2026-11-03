# CSR functional unit (fu_idx 2): impl_compute is empty; Exu overwrites result with csr2exe.rdata (Exu.cpp:461). Only the handshake exists.
module csr_fu

in  en 1 @ bt.exu->units[2]->in.en
in  consume 1 @ bt.exu->units[2]->in.consume

out complete 1 @ bt.exu->in.fu2exu->entry[2].complete
out ready 1 @ bt.exu->in.fu2exu->entry[2].ready
