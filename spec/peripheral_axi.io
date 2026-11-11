# PeripheralAxi (MemSubSystem/PeripheralAxi.cpp), CPU-phase domain (tick 0 only): LSU MMIO/uncached requests -> either served locally by the environment
# (modeled devices: UART/CLINT/INTC/SD/boot) or issued on the EXTRA AXI read/write master.  PeripheralModel / PhysMemory stay in the testbench.
# Boundary = one record per CPU cycle (TTG_MC.pub; q_resp is the final *peripheral_resp after comb_inputs, i.e. what the top-level hold register latches).
# Environment interface (not C++ ports, the testbench side of the cut): env_modeled = address-map decode (1 = device modeled by the environment, 0 = AXI),
# env_rdata = value the environment returns for a locally served read in the cycle it is accepted, env_rd_* = the reads the block asks the environment for
# (C++: PeripheralModel::read_load).  Removed (consumers checked, docs/modules/peripheral_axi.md): req_id (constant 0), AXI req_ready
# (never read), resp_id (never read), resp_data[1..15] and wdata[1..15] (word 0 only), total_size >2 bits.
module peripheral_axi

in  cpu_en                1  @ 1
in  req_is_mmio           1  @ TTG_MC.pub.q_req.is_mmio
in  req_wen               1  @ TTG_MC.pub.q_req.wen
in  req_addr              32 @ TTG_MC.pub.q_req.mmio_addr
in  req_wdata             32 @ TTG_MC.pub.q_req.mmio_wdata
in  req_func3             3  @ TTG_MC.pub.q_req.mmio_fun3
in  env_modeled           1  @ TTG_MC.pub.q_is_modeled
in  env_rdata             32 @ TTG_MC.pub.q_env_rdata
in  axi_rd_req_accepted   1  @ TTG_MC.pub.q_in.read.req_accepted
in  axi_rd_resp_valid     1  @ TTG_MC.pub.q_in.read.resp_valid
in  axi_rd_resp_data      32 @ TTG_MC.pub.q_in.read.resp_data[0]
in  axi_wr_req_accepted   1  @ TTG_MC.pub.q_in.write.req_accepted
in  axi_wr_resp_valid     1  @ TTG_MC.pub.q_in.write.resp_valid

out resp_ready            1  @ TTG_MC.pub.q_resp.ready
out resp_is_mmio          1  @ TTG_MC.pub.q_resp.is_mmio
out resp_rdata            32 when resp_is_mmio @ TTG_MC.pub.q_resp.mmio_rdata
out axi_rd_req_valid      1  @ TTG_MC.pub.q_out.read.req_valid
out axi_rd_req_addr       32 when axi_rd_req_valid @ TTG_MC.pub.q_out.read.req_addr
out axi_rd_req_size       2  when axi_rd_req_valid @ TTG_MC.pub.q_out.read.req_total_size
out axi_rd_resp_ready     1  @ TTG_MC.pub.q_out.read.resp_ready
out axi_wr_req_valid      1  @ TTG_MC.pub.q_out.write.req_valid
out axi_wr_req_addr       32 when axi_wr_req_valid @ TTG_MC.pub.q_out.write.req_addr
out axi_wr_req_size       2  when axi_wr_req_valid @ TTG_MC.pub.q_out.write.req_total_size
out axi_wr_req_wstrb      4  when axi_wr_req_valid @ TTG_MC.pub.q_out.write.req_wstrb & 0xf
out axi_wr_req_wdata      32 when axi_wr_req_valid @ TTG_MC.pub.q_out.write.req_wdata[0]
out axi_wr_resp_ready     1  @ TTG_MC.pub.q_out.write.resp_ready
out env_rd_en             1  @ !TTG_MC.pub.q_cur.busy && !TTG_MC.pub.q_cur.resp_valid && TTG_MC.pub.q_req.is_mmio && !TTG_MC.pub.q_req.wen && TTG_MC.pub.q_is_modeled
out env_rd_addr           32 when env_rd_en @ TTG_MC.pub.q_req.mmio_addr
out env_rd_func3          3  when env_rd_en @ TTG_MC.pub.q_req.mmio_fun3
