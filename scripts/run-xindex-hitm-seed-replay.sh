#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=run
QUICK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE=check
      ;;
    --quick)
      QUICK=1
      ;;
    -h|--help)
      cat <<'EOF'
usage: scripts/run-xindex-hitm-seed-replay.sh [--check] [--quick]

Runs the canonical one-pass XIndex/YCSB-A raw-046 local-versus-CXL experiment.
Use --check to validate inputs and print the resolved settings without
building a binary or starting a benchmark.
Use --quick for one local/CXL pair instead of four pairs. Every row consumes
the complete 400M-operation transaction trace exactly once and then exits.

Common overrides:
  ARBITER_TARGET_NODE  CXL NUMA node, default 2
  REPEATS              local/CXL pairs, default 4
  RESULT_DIR           unique result directory
  BUILD_BENCHMARKS     rebuild XIndex, default 1
  RUN_NATIVE           include a native row per repeat, default 0
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

CONFIG="${ARBITER_HITM_SEED_CONFIG:-${ROOT_DIR}/configs/hitm-seed/candidates/raw-046.config}"
DATA_DIR="${XINDEX_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"
TARGET_NODE="${ARBITER_TARGET_NODE:-2}"
CPU_NODE="${ARBITER_CPU_NODE:-0}"
MEM_NODE="${ARBITER_MEM_NODE:-0}"
if [[ "${QUICK}" == "1" ]]; then
  REPLAY_REPEATS=1
  REPLAY_SHAPE="quick one-pass pair"
else
  REPLAY_REPEATS="${REPEATS:-4}"
  REPLAY_SHAPE="configured one-pass confirmation (${REPLAY_REPEATS} pair(s))"
fi
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-hitm-seed-replay-$(date +%Y%m%d-%H%M%S)}"
HITM_SEED_BUILD_DIR="${HITM_SEED_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-hitm-seed-raw-046}"
ARBITER_BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"
REBUILD="${BUILD_BENCHMARKS:-1}"

if [[ "${CONFIG}" != /* ]]; then
  CONFIG="${ROOT_DIR}/${CONFIG}"
fi
if [[ "${DATA_DIR}" != /* ]]; then
  DATA_DIR="${ROOT_DIR}/${DATA_DIR}"
fi
LOAD_PATH="${DATA_DIR}/xindex_load_ycsb_a.dat"
TX_PATH="${DATA_DIR}/xindex_transaction_ycsb_a.dat"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

resolve_tool() {
  local candidate
  for candidate in "$@"; do
    [[ -z "${candidate}" ]] && continue
    if [[ "${candidate}" == */* ]]; then
      if [[ -x "${candidate}" ]]; then
        printf '%s' "${candidate}"
        return 0
      fi
    elif command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
  done
  return 1
}

prepend_path() {
  local name="$1"
  local value="$2"
  local current="${!name:-}"
  if [[ -d "${value}" ]]; then
    printf -v "${name}" '%s' "${value}${current:+:${current}}"
    export "${name}"
  fi
}

for command in awk date git lscpu numactl pgrep sha256sum systemd-run; do
  require_command "${command}"
done

if [[ "${REBUILD}" != "0" && "${REBUILD}" != "1" ]]; then
  echo "BUILD_BENCHMARKS must be 0 or 1: ${REBUILD}" >&2
  exit 1
fi

CLANGXX_TOOL="${CLANGXX:-}"
OPT_TOOL="${OPT:-}"
if [[ "${REBUILD}" == "1" ]]; then
  if [[ -z "${CLANGXX_TOOL}" ]]; then
    CLANGXX_TOOL="$(resolve_tool \
      "${ROOT_DIR}/.tools/llvm-18.1.8/bin/clang++" \
      /usr/lib/llvm-18/bin/clang++ clang++-18 clang++)" || {
      echo "missing LLVM 18 clang++; set CLANGXX" >&2
      exit 1
    }
  fi
  if [[ -z "${OPT_TOOL}" ]]; then
    OPT_TOOL="$(resolve_tool \
      "${ROOT_DIR}/.tools/llvm18-apt-root/usr/bin/opt-18" \
      /usr/lib/llvm-18/bin/opt opt-18 opt)" || {
      echo "missing LLVM 18 opt; set OPT" >&2
      exit 1
    }
  fi

  if [[ "${CLANGXX_TOOL}" == "${ROOT_DIR}/.tools/"* || \
        "${OPT_TOOL}" == "${ROOT_DIR}/.tools/"* ]]; then
    prepend_path LD_LIBRARY_PATH "${ROOT_DIR}/.tools/libtinfo5-root/lib/x86_64-linux-gnu"
    prepend_path LD_LIBRARY_PATH "${ROOT_DIR}/.tools/libllvm18-root/usr/lib/x86_64-linux-gnu"
    prepend_path LIBRARY_PATH "${ROOT_DIR}/.tools/libstdcxx"
    prepend_path CPLUS_INCLUDE_PATH /usr/include/c++/11/backward
    prepend_path CPLUS_INCLUDE_PATH /usr/include/x86_64-linux-gnu/c++/11
    prepend_path CPLUS_INCLUDE_PATH /usr/include/c++/11
  fi

  CLANG_MAJOR="$("${CLANGXX_TOOL}" --version | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) {split($i,v,"."); print v[1]; exit}}')"
  OPT_MAJOR="$("${OPT_TOOL}" --version | awk '/LLVM version/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) {split($i,v,"."); print v[1]; exit}}')"
  if [[ "${CLANG_MAJOR}" != "18" || "${OPT_MAJOR}" != "18" ]]; then
    echo "replay requires LLVM 18; clang=${CLANG_MAJOR:-unknown}, opt=${OPT_MAJOR:-unknown}" >&2
    exit 1
  fi

  export CLANGXX="${CLANGXX_TOOL}"
  export OPT="${OPT_TOOL}"
fi

if [[ ! "${TARGET_NODE}" =~ ^[0-9]+$ || ! -d "/sys/devices/system/node/node${TARGET_NODE}" ]]; then
  echo "invalid ARBITER_TARGET_NODE=${TARGET_NODE}" >&2
  exit 1
fi
if [[ ! "${CPU_NODE}" =~ ^[0-9]+$ || ! -d "/sys/devices/system/node/node${CPU_NODE}" ]]; then
  echo "invalid ARBITER_CPU_NODE=${CPU_NODE}" >&2
  exit 1
fi
if [[ ! "${MEM_NODE}" =~ ^[0-9]+$ || ! -d "/sys/devices/system/node/node${MEM_NODE}" ]]; then
  echo "invalid ARBITER_MEM_NODE=${MEM_NODE}" >&2
  exit 1
fi
if [[ "${TARGET_NODE}" == "${MEM_NODE}" ]]; then
  echo "target and local memory nodes must differ" >&2
  exit 1
fi
if [[ ! "${REPLAY_REPEATS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "REPEATS must be a positive integer: ${REPLAY_REPEATS}" >&2
  exit 1
fi
for path in "${CONFIG}" "${LOAD_PATH}" "${TX_PATH}"; do
  if [[ ! -s "${path}" ]]; then
    echo "missing required replay input: ${path}" >&2
    exit 1
  fi
done

CPU_COUNT="$(lscpu -p=CPU,NODE | awk -F, -v node="${CPU_NODE}" '$1 !~ /^#/ && $2 == node {count++} END {print count + 0}')"
if [[ "${CPU_COUNT}" -lt 32 ]]; then
  echo "node ${CPU_NODE} has ${CPU_COUNT} CPUs; replay requires at least 32" >&2
  exit 1
fi

TARGET_CPUS="$(cat "/sys/devices/system/node/node${TARGET_NODE}/cpulist")"
TARGET_MEMORY_KB="$(awk '/MemTotal/ {print $4}' "/sys/devices/system/node/node${TARGET_NODE}/meminfo")"

cat <<EOF
XIndex HITM-risk seed replay settings:
  config:             ${CONFIG}
  load / tx records:  100000000 / 400000000
  execution mode:     iteration=1, duration=0 (400M operations once)
  throughput samples: disabled
  repeats:            ${REPLAY_REPEATS}
  replay shape:       ${REPLAY_SHAPE}
  workers:            31 foreground + 1 background
  CPU / local / CXL:  ${CPU_NODE} / ${MEM_NODE} / ${TARGET_NODE}
  target node CPUs:   ${TARGET_CPUS:-none}
  target memory:      ${TARGET_MEMORY_KB} KiB
  memory / swap cap:  64G / 0
  arena capacity:     25769803776 bytes
  rebuild / clang++:  ${REBUILD} / ${CLANGXX_TOOL:-not required}
  opt:                ${OPT_TOOL:-not required}
  result:             ${RESULT_DIR}
  cache policy:       fresh process; warm filesystem cache; no drop_caches
EOF

if [[ "${MODE}" == check ]]; then
  echo "check-only mode: no build, result directory, or benchmark was started"
  exit 0
fi

if [[ -e "${RESULT_DIR}/runs.csv" ]]; then
  echo "result already exists: ${RESULT_DIR}/runs.csv" >&2
  exit 1
fi
if pgrep -af '[y]csb_bench' >/dev/null 2>&1 && [[ "${ALLOW_BUSY_HOST:-0}" != "1" ]]; then
  echo "another ycsb_bench process is running; use a quiet host or set ALLOW_BUSY_HOST=1" >&2
  exit 1
fi

mkdir -p "${RESULT_DIR}"
{
  echo "started_at=$(date --iso-8601=seconds)"
  echo "git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  echo "git_dirty_files=$(git -C "${ROOT_DIR}" status --porcelain | wc -l)"
  echo "config=${CONFIG}"
  echo "config_sha256=$(sha256sum "${CONFIG}" | awk '{print $1}')"
  echo "data_dir=${DATA_DIR}"
  echo "load_records=100000000"
  echo "transaction_ops=400000000"
  echo "execution_mode=iteration"
  echo "iteration=1"
  echo "duration_seconds=0"
  echo "sample_seconds=0"
  echo "repeats=${REPLAY_REPEATS}"
  echo "foreground_threads=31"
  echo "background_threads=1"
  echo "cpu_node=${CPU_NODE}"
  echo "local_memory_node=${MEM_NODE}"
  echo "target_memory_node=${TARGET_NODE}"
  echo "memory_max=64G"
  echo "memory_swap_max=0"
  echo "arena_slab_bytes=2097152"
  echo "arena_reserve_bytes=25769803776"
  echo "arena_slot_alignment=64"
  echo "build_benchmarks=${REBUILD}"
  echo "clangxx=${CLANGXX_TOOL:-not required}"
  echo "opt=${OPT_TOOL:-not required}"
  echo "cache_policy=fresh process per row; filesystem page cache not dropped; CPU cache not flushed"
  echo
  numactl --hardware
} > "${RESULT_DIR}/replay-manifest.txt"

exec env \
  RESULT_DIR="${RESULT_DIR}" \
  HITM_SEED_BUILD_DIR="${HITM_SEED_BUILD_DIR}" \
  XINDEX_SCALE_DATA_DIR="${DATA_DIR}" \
  XINDEX_SCALE_LOAD_RECORDS=100000000 \
  XINDEX_SCALE_TX_OPS=400000000 \
  XINDEX_ITERATION=1 \
  XINDEX_DURATION_SECONDS=0 \
  XINDEX_THROUGHPUT_SAMPLE_SECONDS=0 \
  XINDEX_FG=31 \
  XINDEX_BG=1 \
  YCSB_TYPES=a \
  REPEATS="${REPLAY_REPEATS}" \
  ARBITER_CPU_NODE="${CPU_NODE}" \
  ARBITER_MEM_NODE="${MEM_NODE}" \
  ARBITER_TARGET_NODE="${TARGET_NODE}" \
  ARBITER_HITM_SEED_CONFIG="${CONFIG}" \
  ARBITER_HEAP_BACKEND=arena \
  ARBITER_ARENA_SLAB_BYTES=2097152 \
  ARBITER_ARENA_RESERVE_BYTES=25769803776 \
  ARBITER_ARENA_SLOT_ALIGNMENT=64 \
  ARBITER_ARENA_STRICT=1 \
  ARBITER_ARENA_REPORT=1 \
  MEMORY_MAX=64G \
  MEMORY_SWAP_MAX=0 \
  RUN_NATIVE="${RUN_NATIVE:-0}" \
  RUN_LOCAL=1 \
  RUN_TARGET=1 \
  BUILD_BENCHMARKS="${REBUILD}" \
  PREPARE_SCALE_DATA=0 \
  FAIL_FAST=1 \
  ALTERNATE_PLACEMENT_ORDER=1 \
  FIRST_PLACEMENT=local \
  COOLDOWN_SECONDS=2 \
  USE_SYSTEMD_SCOPE=1 \
  ARBITER_BUILD_DIR="${ARBITER_BUILD_DIR}" \
  CLANGXX="${CLANGXX_TOOL}" \
  OPT="${OPT_TOOL}" \
  LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
  LIBRARY_PATH="${LIBRARY_PATH:-}" \
  CPLUS_INCLUDE_PATH="${CPLUS_INCLUDE_PATH:-}" \
  "${ROOT_DIR}/scripts/run-protected-hitm-seed-experiment.sh"
