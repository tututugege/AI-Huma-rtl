.PHONY: selftest lint cfg clean prims
selftest:   ## validate the harness itself (clean RTL passes, seeded bugs are caught)
	bash tests/selftest/run.sh
lint:       ## style rules + verilator -Wall on rtl/
	bash scripts/lint.sh
cfg:        ## regenerate rtl/common/ttg_cfg_pkg.sv from the reference simulator config.h
	bash scripts/gen_cfg.sh
clean:
	rm -rf build traces

prims:      ## exhaustive test of rtl/common primitives
	verilator --binary --timing -Wno-fatal -Irtl/common rtl/common/ttg_*.sv tests/common/prims_tb.sv --top-module prims_tb -Mdir build/prims >/dev/null 2>&1
	build/prims/Vprims_tb | grep PRIMS
