#!/usr/bin/env bash
# Run lockstep_all.sh for several modules, JOBS at a time.   usage: lockstep_batch.sh <module>...    env JOBS (default 3)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
printf '%s\n' "$@" | xargs -P "${JOBS:-3}" -I{} bash "$ROOT/scripts/lockstep_all.sh" {} 2>&1 | grep -a "^=="
