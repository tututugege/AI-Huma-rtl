.PHONY: selftest lint cfg clean
selftest:   ## validate the harness itself (clean RTL passes, seeded bugs are caught)
	bash tests/selftest/run.sh
lint:       ## style rules + verilator -Wall on rtl/
	bash scripts/lint.sh
cfg:        ## regenerate rtl/common/ttg_cfg_pkg.sv from the reference simulator config.h
	bash scripts/gen_cfg.sh
clean:
	rm -rf build traces
