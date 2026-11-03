#!/usr/bin/env bash
# Coordinator: merge finished module branches (rtl/<mod>) into main, one by one; stops at the first conflict.
#   usage: merge_modules.sh <mod>...
set -uo pipefail
cd "$(dirname "$0")/.."
G="git -c user.name=ruyaoh -c user.email=ruyaoh@nvidia.com"
for m in "$@"; do
  if $G merge --no-ff -q "rtl/$m" -m "Merge rtl/$m: $m translated to SV (green, reviewed)" 2>&1 | tail -3; then :; fi
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then echo "CONFLICT merging $m:"; git diff --name-only --diff-filter=U; exit 1; fi
  echo "merged $m -> $(git log --oneline | head -1 | cut -c1-80)"
done
