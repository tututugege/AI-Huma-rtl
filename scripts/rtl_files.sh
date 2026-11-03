#!/usr/bin/env bash
# Print every .sv under <dir>/rtl in compile order: packages first (ttg_cfg_pkg, then other *_pkg.sv), then the rest.
#   usage: rtl_files.sh [root]
R=${1:-.}
cd "$R" || exit 1
echo rtl/common/ttg_cfg_pkg.sv
find rtl -name '*_pkg.sv' ! -name ttg_cfg_pkg.sv | sort
find rtl -name '*.sv' ! -name '*_pkg.sv' | sort
