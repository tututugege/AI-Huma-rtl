#!/usr/bin/env bash
# Print every .sv under <dir>/rtl in compile order: packages first (ttg_cfg_pkg, the other rtl/common packages, then the rest of *_pkg.sv),
# then the rest (a package may import an rtl/common package, e.g. ttg_util_pkg).
#   usage: rtl_files.sh [root]
R=${1:-.}
cd "$R" || exit 1
echo rtl/common/ttg_cfg_pkg.sv
find rtl/common -name '*_pkg.sv' ! -name ttg_cfg_pkg.sv | sort
find rtl -name '*_pkg.sv' ! -path 'rtl/common/*' | sort
find rtl -name '*.sv' ! -name '*_pkg.sv' | sort
