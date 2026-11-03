#!/usr/bin/env bash
# Coordinator: record the extra programs (vm tests, float, sha, cjpeg, ...) for each module worktree and replay them
# against the branch's RTL.   usage: extra_check.sh <mod>...     (worktrees under /Users/ruyaoh/personal/rtl-wt/<mod>)
set -uo pipefail
MAIN=$(cd "$(dirname "$0")/.." && pwd)
NAMES="vm_asid_test vm_pagefault_test vm_sfence_perm_test vm_sum_fetch_test float_test sha-test cjpeg linear_alg-mid-100x100-sp parser-125k"
for m in "$@"; do
  W=/Users/ruyaoh/personal/rtl-wt/$m
  echo "=== $m: recording extra programs"
  ( cd "$W" && EXTRA_ONLY=1 SKIP_EXISTING=1 JOBS=2 bash scripts/record_all.sh "$m" 2>&1 | tail -3 )
  echo "=== $m: replay"
  bash "$MAIN/scripts/review.sh" "$W" "$m" $NAMES 2>&1 | tail -12
done
