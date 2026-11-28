#!/usr/bin/env bash
# Unified AI-Huma Fast PPA Wrapper across Tier 0 / 0-elab / 1 / 2a / 2b
# Refuses running heavy synthesis (Tier 1/2a/2b) on iprc-jump or login-inband.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NFS_EVAL_ROOT="/nfs_global/S/houruyao/fast_ppa_eval"

TIER="1"
MOD="front_top"
SRAM_MODE=""
EFFORT="dc-ultra-relax"
CLK_NS=""
UNC_NS=""
IO_NS=""
OUT_DIR=""
CORES="16"
BPU_DDC=""
ICACHE_DDC=""
RTL_ROOT=""
HOST=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
  --tier <0|0-elab|1|2a|2b>   Estimation tier (default: 1)
  --mod <module|all>          Target module (default: front_top; 'all' supported in tier 0/0-elab)
  --mode <real|bb|none>       SRAM handling mode (default: auto per module)
  --effort <mode>             Tier 2a effort: dc-ultra-relax|dc-ultra-fast|dc-low|dc-med|dc-low-relax
  --clk <ns>                  Clock period in ns (default: 0.65 frontend / 0.50 backend+mmu)
  --unc <ns>                  Clock uncertainty in ns (default: 0.05 frontend / 0.03 others)
  --io <ns>                   Input/output delay in ns (default: 0.12 frontend / 0.05 others)
  --out <dir>                 Output directory (default: <eval_root>/ad_hoc/<tier>_<mod>)
  --cores <n>                 DC max_cores for Tier 2a/2b (default: 16)
  --bpu-ddc <path>            Precompiled bpu.ddc for Tier 2b
  --icache-ddc <path>         Precompiled icache.ddc for Tier 2b
  --rtl-root <path>           RTL root containing rtl/ and optional files.f
  --host <eda-XX>             Dispatch command to remote eda compute node via ssh
  -h, --help                  Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tier)       TIER="$2"; shift 2 ;;
    --mod)        MOD="$2"; shift 2 ;;
    --mode)       SRAM_MODE="$2"; shift 2 ;;
    --effort)     EFFORT="$2"; shift 2 ;;
    --clk)        CLK_NS="$2"; shift 2 ;;
    --unc)        UNC_NS="$2"; shift 2 ;;
    --io)         IO_NS="$2"; shift 2 ;;
    --out)        OUT_DIR="$2"; shift 2 ;;
    --cores)      CORES="$2"; shift 2 ;;
    --bpu-ddc)    BPU_DDC="$2"; shift 2 ;;
    --icache-ddc) ICACHE_DDC="$2"; shift 2 ;;
    --rtl-root)   RTL_ROOT="$2"; shift 2 ;;
    --host)       HOST="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Auto-defaults per module
if [ -z "$SRAM_MODE" ]; then
  case "$MOD" in
    tlb_mmu|ftq_ibuf) SRAM_MODE="bb" ;;
    isu|lsu)          SRAM_MODE="none" ;;
    *)                SRAM_MODE="real" ;;
  esac
fi

if [ -z "$CLK_NS" ]; then
  case "$MOD" in
    bpu|icache|front_top) CLK_NS="0.65"; UNC_NS="${UNC_NS:-0.05}"; IO_NS="${IO_NS:-0.12}" ;;
    *)                    CLK_NS="0.50"; UNC_NS="${UNC_NS:-0.03}"; IO_NS="${IO_NS:-0.05}" ;;
  esac
else
  UNC_NS="${UNC_NS:-0.05}"
  IO_NS="${IO_NS:-0.12}"
fi

# If --host is specified and we are not already on that host, forward via SSH
CUR_HOST="$(hostname -s)"
if [ -n "$HOST" ] && [ "$CUR_HOST" != "$HOST" ]; then
  if [ "$HOST" = "login-inband" ] || [ "$HOST" = "iprc-jump" ]; then
    echo "ERROR: Refusing to dispatch heavy/PDK jobs onto $HOST; use eda-04..eda-10." >&2
    exit 1
  fi
  REMOTE_OUT="${OUT_DIR:-$NFS_EVAL_ROOT/ad_hoc/${TIER}_${MOD}}"
  REMOTE_RTL="${RTL_ROOT:-$NFS_EVAL_ROOT}"
  CMD_ARGS=(--tier "$TIER" --mod "$MOD" --mode "$SRAM_MODE" --effort "$EFFORT" --clk "$CLK_NS" --unc "$UNC_NS" --io "$IO_NS" --out "$REMOTE_OUT" --cores "$CORES" --rtl-root "$REMOTE_RTL")
  [ -n "$BPU_DDC" ] && CMD_ARGS+=(--bpu-ddc "$BPU_DDC")
  [ -n "$ICACHE_DDC" ] && CMD_ARGS+=(--icache-ddc "$ICACHE_DDC")
  QARGS=$(printf '%q ' "${CMD_ARGS[@]}")
  exec ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" "bash $NFS_EVAL_ROOT/scripts/fast_ppa.sh $QARGS"
fi

# Local execution guardrails (refuse hosts without PDK such as iprc-jump, and refuse login-inband)
if [[ "$CUR_HOST" == "login-inband"* ]] || [ ! -d "/eda-tools/pdk/TSMC28" ]; then
  echo "ERROR: Cannot run Tier $TIER directly on $CUR_HOST (missing /eda-tools/pdk/TSMC28 or login-inband forbidden). Pass --host eda-05..eda-10." >&2
  exit 1
fi

# Resolve RTL_ROOT & ensure files.f exists when running Tier 0-elab / 1 / 2a / 2b
if [ -z "$RTL_ROOT" ]; then
  if [ -f "$REPO_ROOT/rtl/rtl/common/ttg_cfg_pkg.sv" ]; then
    RTL_ROOT="$REPO_ROOT/rtl"
  else
    RTL_ROOT="$NFS_EVAL_ROOT"
  fi
fi

ensure_files_f() {
  if [ ! -f "$RTL_ROOT/files.f" ]; then
    local gen_dir="${OUT_DIR:-/tmp/fast_ppa_files_$$}"
    mkdir -p "$gen_dir"
    local list_py="$SCRIPT_DIR/list_sv_files.py"
    [ -f "$list_py" ] || list_py="$NFS_EVAL_ROOT/scripts/list_sv_files.py"
    python3 "$list_py" --rtl-dir "$RTL_ROOT/rtl" --out "$gen_dir/files.f"
    # Stage lightweight symlink wrapper dir if files.f is outside RTL_ROOT
    ln -sfn "$RTL_ROOT/rtl" "$gen_dir/rtl"
    RTL_ROOT="$gen_dir"
  fi
}

find_script() {
  local name="$1"
  if [ -f "$SCRIPT_DIR/$name" ]; then
    echo "$SCRIPT_DIR/$name"
  elif [ -f "$REPO_ROOT/scripts/$name" ]; then
    echo "$REPO_ROOT/scripts/$name"
  else
    echo "$NFS_EVAL_ROOT/scripts/$name"
  fi
}

OUT_DIR="${OUT_DIR:-$NFS_EVAL_ROOT/ad_hoc/${TIER}_${MOD}}"

case "$TIER" in
  0)
    PPA_PY="$(find_script ppa_est.py)"
    exec python3 "$PPA_PY" --module "$MOD" --mode analytical --sram-mode "$SRAM_MODE" --rtl-root "$RTL_ROOT"
    ;;
  0-elab)
    ensure_files_f
    PPA_PY="$(find_script ppa_est.py)"
    exec python3 "$PPA_PY" --module "$MOD" --mode elab --sram-mode "$SRAM_MODE" --rtl-root "$RTL_ROOT" --files-f "$RTL_ROOT/files.f"
    ;;
  1)
    ensure_files_f
    T1_SH="$(find_script run_tier1_yosys_pt.sh)"
    exec bash "$T1_SH" "$MOD" "$SRAM_MODE" "$CLK_NS" "$UNC_NS" "$IO_NS" "$OUT_DIR" "$RTL_ROOT"
    ;;
  2a)
    ensure_files_f
    T2A_SH="$(find_script run_tier2_dc_fast.sh)"
    exec bash "$T2A_SH" "$MOD" "$SRAM_MODE" "$EFFORT" "$CLK_NS" "$UNC_NS" "$IO_NS" "$OUT_DIR" "$CORES" "$RTL_ROOT"
    ;;
  2b)
    if [ "$MOD" != "front_top" ]; then
      echo "ERROR: Tier 2b incremental assembly currently supports --mod front_top only (got $MOD)." >&2
      exit 1
    fi
    if [ -z "$BPU_DDC" ] || [ -z "$ICACHE_DDC" ]; then
      echo "ERROR: Tier 2b requires --bpu-ddc and --icache-ddc." >&2
      exit 1
    fi
    ensure_files_f
    T2B_SH="$(find_script run_tier2b_dc_inc.sh)"
    exec bash "$T2B_SH" "$BPU_DDC" "$ICACHE_DDC" "$CLK_NS" "$UNC_NS" "$IO_NS" "$OUT_DIR" "$CORES" "$RTL_ROOT"
    ;;
  *)
    echo "ERROR: Unknown --tier $TIER (expected 0|0-elab|1|2a|2b)" >&2
    exit 1
    ;;
esac
