#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOAD_RECORDS="${XINDEX_SCALE_LOAD_RECORDS:-100000}"
TX_OPS="${XINDEX_SCALE_TX_OPS:-400000}"
YCSB_TYPES="${YCSB_TYPES:-${YCSB_TYPE:-a}}"
HOTSET_CONFIG="${ARBITER_HOTSET_CONFIG:-configs/hotset/xindex-cxl-arena.config}"
HOTSET_CONFIG_PATH="${HOTSET_CONFIG}"
if [[ "${HOTSET_CONFIG_PATH}" != /* ]]; then
  HOTSET_CONFIG_PATH="${ROOT_DIR}/${HOTSET_CONFIG_PATH}"
fi
CONFIG_NAME="$(basename "${HOTSET_CONFIG_PATH}")"
CONFIG_NAME="${CONFIG_NAME%.config}"
BUILD_NAME="${CONFIG_NAME#xindex-}"

RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/hotset-${CONFIG_NAME}-${LOAD_RECORDS}-${TX_OPS}}"
HOTSET_BUILD_DIR="${HOTSET_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-hotset-${BUILD_NAME}}"
XINDEX_SCALE_DATA_DIR="${XINDEX_SCALE_DATA_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_scale_${LOAD_RECORDS}_${TX_OPS}}"
MEMORY_MAX="${MEMORY_MAX:-16G}"
MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-0}"
USE_SYSTEMD_SCOPE="${USE_SYSTEMD_SCOPE:-1}"

REPEATS="${REPEATS:-1}"
XINDEX_FG="${XINDEX_FG:-8}"
XINDEX_BG="${XINDEX_BG:-1}"
XINDEX_ITERATION="${XINDEX_ITERATION:-3}"
XINDEX_DURATION_SECONDS="${XINDEX_DURATION_SECONDS:-60}"
XINDEX_THROUGHPUT_SAMPLE_SECONDS="${XINDEX_THROUGHPUT_SAMPLE_SECONDS:-0}"
CPU_NODE="${ARBITER_CPU_NODE:-0}"
MEM_NODE="${ARBITER_MEM_NODE:-0}"
TARGET_NODE="${ARBITER_TARGET_NODE:-}"
RUN_NATIVE="${RUN_NATIVE:-1}"
RUN_LOCAL="${RUN_LOCAL:-1}"
RUN_TARGET="${RUN_TARGET:-1}"
BUILD_BENCHMARKS="${BUILD_BENCHMARKS:-1}"
PREPARE_SCALE_DATA="${PREPARE_SCALE_DATA:-1}"
FAIL_FAST="${FAIL_FAST:-0}"
ALTERNATE_PLACEMENT_ORDER="${ALTERNATE_PLACEMENT_ORDER:-0}"
FIRST_PLACEMENT="${FIRST_PLACEMENT:-local}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-0}"
HEAP_BACKEND="${ARBITER_HEAP_BACKEND:-arena}"
ARENA_SLAB_BYTES="${ARBITER_ARENA_SLAB_BYTES:-2097152}"
ARENA_RESERVE_BYTES="${ARBITER_ARENA_RESERVE_BYTES:-4294967296}"
ARENA_SLOT_ALIGNMENT="${ARBITER_ARENA_SLOT_ALIGNMENT:-64}"
ARENA_STRICT="${ARBITER_ARENA_STRICT:-1}"
ARENA_REPORT="${ARBITER_ARENA_REPORT:-1}"

usage() {
  cat <<EOF
usage: $0

Builds one configured XIndex hot-set binary and compares the same binary with
local allocation and target-node allocation inside a protected memory scope.

Defaults:
  hot-set config:      configs/hotset/xindex-cxl-arena.config
  load records:       100000
  transaction ops:    400000
  workloads:          a
  repeats:            1
  foreground threads: 8
  background threads: 1
  duration:           60 seconds per measured run
  iterations:         3 (used only when duration is 0)
  MemoryMax:          16G
  MemorySwapMax:      0

Required for target runs:
  ARBITER_TARGET_NODE       NUMA node containing target/CXL memory

Useful environment:
  ARBITER_HOTSET_CONFIG     sourced build-time hot-set config
  RESULT_DIR                result directory
  HOTSET_BUILD_DIR          hot-set build output directory
  XINDEX_SCALE_LOAD_RECORDS scaled load records
  XINDEX_SCALE_TX_OPS       scaled transaction operations
  YCSB_TYPES                workload list, such as "a" or "a b"
  REPEATS                   default: 1
  XINDEX_FG                 default: 8
  XINDEX_BG                 default: 1
  XINDEX_ITERATION          default: 3
  XINDEX_DURATION_SECONDS   default: 60; set 0 for iteration mode
  XINDEX_THROUGHPUT_SAMPLE_SECONDS
                           default: 0; 10 for short, 60 for long runs
  ARBITER_CPU_NODE          default: 0
  ARBITER_MEM_NODE          default: 0
  MEMORY_MAX               default: 16G
  MEMORY_SWAP_MAX          default: 0
  BUILD_BENCHMARKS         default: 1
  PREPARE_SCALE_DATA       default: 1; set 0 only for validated existing traces
  FAIL_FAST               default: 0; stop after the first failed run
  FIRST_PLACEMENT         local or target; default: local
  COOLDOWN_SECONDS        default: 0; pause after every measured row
  ALTERNATE_PLACEMENT_ORDER
                           default: 0; alternate local/target order by repeat
  ARBITER_HEAP_BACKEND     direct or arena; default: arena
  ARBITER_ARENA_SLAB_BYTES default: 2097152 (2 MiB)
  ARBITER_ARENA_RESERVE_BYTES
                           default: 4294967296 (4 GiB hard arena capacity)
  ARBITER_ARENA_SLOT_ALIGNMENT
                           default: 64
  ARBITER_ARENA_STRICT     default: 1 (no direct-allocation fallback)
  ARBITER_ARENA_REPORT     default: 1
  RUN_NATIVE               default: 1
  RUN_LOCAL                default: 1
  RUN_TARGET               default: 1
  USE_SYSTEMD_SCOPE        default: 1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${name} must be a positive integer: ${value}" >&2
    exit 1
  fi
}

require_nonnegative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "${name} must be a non-negative integer: ${value}" >&2
    exit 1
  fi
}

require_toggle() {
  local name="$1"
  local value="$2"
  if [[ "${value}" != "0" && "${value}" != "1" ]]; then
    echo "${name} must be 0 or 1: ${value}" >&2
    exit 1
  fi
}

require_positive_integer XINDEX_SCALE_LOAD_RECORDS "${LOAD_RECORDS}"
require_positive_integer XINDEX_SCALE_TX_OPS "${TX_OPS}"
require_positive_integer REPEATS "${REPEATS}"
require_positive_integer XINDEX_FG "${XINDEX_FG}"
require_nonnegative_integer XINDEX_BG "${XINDEX_BG}"
require_positive_integer XINDEX_ITERATION "${XINDEX_ITERATION}"
require_nonnegative_integer XINDEX_DURATION_SECONDS "${XINDEX_DURATION_SECONDS}"
require_nonnegative_integer XINDEX_THROUGHPUT_SAMPLE_SECONDS "${XINDEX_THROUGHPUT_SAMPLE_SECONDS}"
require_nonnegative_integer COOLDOWN_SECONDS "${COOLDOWN_SECONDS}"
require_positive_integer ARBITER_ARENA_SLAB_BYTES "${ARENA_SLAB_BYTES}"
require_positive_integer ARBITER_ARENA_RESERVE_BYTES "${ARENA_RESERVE_BYTES}"
require_positive_integer ARBITER_ARENA_SLOT_ALIGNMENT "${ARENA_SLOT_ALIGNMENT}"
require_toggle RUN_NATIVE "${RUN_NATIVE}"
require_toggle RUN_LOCAL "${RUN_LOCAL}"
require_toggle RUN_TARGET "${RUN_TARGET}"
require_toggle BUILD_BENCHMARKS "${BUILD_BENCHMARKS}"
require_toggle PREPARE_SCALE_DATA "${PREPARE_SCALE_DATA}"
require_toggle FAIL_FAST "${FAIL_FAST}"
require_toggle ALTERNATE_PLACEMENT_ORDER "${ALTERNATE_PLACEMENT_ORDER}"
require_toggle ARBITER_ARENA_STRICT "${ARENA_STRICT}"
require_toggle ARBITER_ARENA_REPORT "${ARENA_REPORT}"

if [[ "${FIRST_PLACEMENT}" != "local" && "${FIRST_PLACEMENT}" != "target" ]]; then
  echo "FIRST_PLACEMENT must be local or target: ${FIRST_PLACEMENT}" >&2
  exit 1
fi

if [[ "${HEAP_BACKEND}" != "direct" && "${HEAP_BACKEND}" != "arena" ]]; then
  echo "ARBITER_HEAP_BACKEND must be direct or arena: ${HEAP_BACKEND}" >&2
  exit 1
fi

if [[ "${HEAP_BACKEND}" == "arena" && "${ARENA_STRICT}" != "1" ]]; then
  echo "the protected arena comparison requires ARBITER_ARENA_STRICT=1" >&2
  exit 1
fi
if [[ "${HEAP_BACKEND}" == "arena" && "${ARENA_REPORT}" != "1" ]]; then
  echo "the protected arena comparison requires ARBITER_ARENA_REPORT=1" >&2
  exit 1
fi

if [[ ! "${MEM_NODE}" =~ ^[0-9]+$ || ! -d "/sys/devices/system/node/node${MEM_NODE}" ]]; then
  echo "invalid ARBITER_MEM_NODE=${MEM_NODE}" >&2
  exit 1
fi

if [[ ! -f "${HOTSET_CONFIG_PATH}" ]]; then
  echo "missing ARBITER_HOTSET_CONFIG=${HOTSET_CONFIG}" >&2
  exit 1
fi

EXPECTED_SEED_FUNCTION="$(
  ARBITER_HOTSET_EXPECTED_SEED_FUNCTION=
  # shellcheck source=/dev/null
  source "${HOTSET_CONFIG_PATH}"
  printf '%s' "${ARBITER_HOTSET_EXPECTED_SEED_FUNCTION:-}"
)"
EXPECTED_SEED_COUNT="$(
  ARBITER_HOTSET_EXPECTED_SEED_COUNT=
  # shellcheck source=/dev/null
  source "${HOTSET_CONFIG_PATH}"
  printf '%s' "${ARBITER_HOTSET_EXPECTED_SEED_COUNT:-}"
)"
EXPECTED_MEMBER_COUNT="$(
  ARBITER_HOTSET_EXPECTED_MEMBER_COUNT=
  # shellcheck source=/dev/null
  source "${HOTSET_CONFIG_PATH}"
  printf '%s' "${ARBITER_HOTSET_EXPECTED_MEMBER_COUNT:-}"
)"

if [[ "${RUN_TARGET}" == "1" ]]; then
  if [[ -z "${TARGET_NODE}" ]]; then
    echo "ARBITER_TARGET_NODE is required when RUN_TARGET=1" >&2
    exit 1
  fi
  if [[ ! "${TARGET_NODE}" =~ ^[0-9]+$ || ! -d "/sys/devices/system/node/node${TARGET_NODE}" ]]; then
    echo "invalid ARBITER_TARGET_NODE=${TARGET_NODE}" >&2
    exit 1
  fi
fi

if [[ "${USE_SYSTEMD_SCOPE}" == "1" && "${PROTECTED_SCOPE_ACTIVE:-0}" != "1" ]]; then
  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "systemd-run is required; set USE_SYSTEMD_SCOPE=0 only for an externally protected run" >&2
    exit 1
  fi

  mkdir -p "${RESULT_DIR}"
  cat <<EOF
Starting protected hot-set scope:
  MemoryMax=${MEMORY_MAX}
  MemorySwapMax=${MEMORY_SWAP_MAX}
  config=${HOTSET_CONFIG_PATH}
  target_node=${TARGET_NODE:-disabled}
  heap_backend=${HEAP_BACKEND}
  arena_slab_bytes=${ARENA_SLAB_BYTES}
  arena_reserve_bytes=${ARENA_RESERVE_BYTES}
  duration_seconds=${XINDEX_DURATION_SECONDS}
  result=${RESULT_DIR}
EOF

  exec systemd-run --user --scope \
    -p "MemoryMax=${MEMORY_MAX}" \
    -p "MemorySwapMax=${MEMORY_SWAP_MAX}" \
    env \
      PROTECTED_SCOPE_ACTIVE=1 \
      USE_SYSTEMD_SCOPE="${USE_SYSTEMD_SCOPE}" \
      MEMORY_MAX="${MEMORY_MAX}" \
      MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX}" \
      ARBITER_HOTSET_CONFIG="${HOTSET_CONFIG_PATH}" \
      RESULT_DIR="${RESULT_DIR}" \
      HOTSET_BUILD_DIR="${HOTSET_BUILD_DIR}" \
      XINDEX_SCALE_DATA_DIR="${XINDEX_SCALE_DATA_DIR}" \
      XINDEX_SCALE_LOAD_RECORDS="${LOAD_RECORDS}" \
      XINDEX_SCALE_TX_OPS="${TX_OPS}" \
      YCSB_TYPES="${YCSB_TYPES}" \
      REPEATS="${REPEATS}" \
      XINDEX_FG="${XINDEX_FG}" \
      XINDEX_BG="${XINDEX_BG}" \
      XINDEX_ITERATION="${XINDEX_ITERATION}" \
      XINDEX_DURATION_SECONDS="${XINDEX_DURATION_SECONDS}" \
      XINDEX_THROUGHPUT_SAMPLE_SECONDS="${XINDEX_THROUGHPUT_SAMPLE_SECONDS}" \
      ARBITER_CPU_NODE="${CPU_NODE}" \
      ARBITER_MEM_NODE="${MEM_NODE}" \
      ARBITER_TARGET_NODE="${TARGET_NODE}" \
      RUN_NATIVE="${RUN_NATIVE}" \
      RUN_LOCAL="${RUN_LOCAL}" \
      RUN_TARGET="${RUN_TARGET}" \
      BUILD_BENCHMARKS="${BUILD_BENCHMARKS}" \
      PREPARE_SCALE_DATA="${PREPARE_SCALE_DATA}" \
      FAIL_FAST="${FAIL_FAST}" \
      ALTERNATE_PLACEMENT_ORDER="${ALTERNATE_PLACEMENT_ORDER}" \
      FIRST_PLACEMENT="${FIRST_PLACEMENT}" \
      COOLDOWN_SECONDS="${COOLDOWN_SECONDS}" \
      ARBITER_HEAP_BACKEND="${HEAP_BACKEND}" \
      ARBITER_ARENA_SLAB_BYTES="${ARENA_SLAB_BYTES}" \
      ARBITER_ARENA_RESERVE_BYTES="${ARENA_RESERVE_BYTES}" \
      ARBITER_ARENA_SLOT_ALIGNMENT="${ARENA_SLOT_ALIGNMENT}" \
      ARBITER_ARENA_STRICT="${ARENA_STRICT}" \
      ARBITER_ARENA_REPORT="${ARENA_REPORT}" \
      XINDEX_DATA_DIR="${XINDEX_DATA_DIR:-}" \
      ARBITER_BUILD_DIR="${ARBITER_BUILD_DIR:-}" \
      CLANGXX="${CLANGXX:-}" \
      OPT="${OPT:-}" \
      MKL_INCLUDE_DIR="${MKL_INCLUDE_DIR:-}" \
      MKL_LINK_DIR="${MKL_LINK_DIR:-}" \
      MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR:-}" \
      LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" \
      LIBRARY_PATH="${LIBRARY_PATH:-}" \
      CPLUS_INCLUDE_PATH="${CPLUS_INCLUDE_PATH:-}" \
      "$0" "$@"
fi

if [[ "${PROTECTED_SCOPE_ACTIVE:-0}" == "1" ]]; then
  echo 1000 > "/proc/$$/oom_score_adj" 2>/dev/null || true
fi

if [[ -n "${XINDEX_DATA_DIR:-}" ]]; then
  export XINDEX_DATA_DIR
else
  unset XINDEX_DATA_DIR
fi
export XINDEX_SCALE_LOAD_RECORDS="${LOAD_RECORDS}"
export XINDEX_SCALE_TX_OPS="${TX_OPS}"
export XINDEX_SCALE_DATA_DIR
export YCSB_TYPES
if [[ "${PREPARE_SCALE_DATA}" == "1" ]]; then
  "${ROOT_DIR}/scripts/prepare-xindex-ycsb-scale-data.sh"
else
  for workload in ${YCSB_TYPES}; do
    load_path="${XINDEX_SCALE_DATA_DIR}/xindex_load_ycsb_${workload}.dat"
    tx_path="${XINDEX_SCALE_DATA_DIR}/xindex_transaction_ycsb_${workload}.dat"
    if [[ "${workload}" != "a" && ! -s "${load_path}" ]]; then
      load_path="${XINDEX_SCALE_DATA_DIR}/xindex_load_ycsb_a.dat"
    fi
    if [[ ! -s "${load_path}" || ! -s "${tx_path}" ]]; then
      echo "missing validated scaled trace with PREPARE_SCALE_DATA=0: ${load_path} or ${tx_path}" >&2
      exit 1
    fi
  done
fi

BUILD_CONFIG_COPY="${HOTSET_BUILD_DIR}/hotset-build.config"
if [[ "${BUILD_BENCHMARKS}" == "1" ]]; then
  ARBITER_BENCH_BUILD_DIR="${HOTSET_BUILD_DIR}" \
    ARBITER_XINDEX_EXPERIMENT=hotset \
    ARBITER_HOTSET_CONFIG="${HOTSET_CONFIG_PATH}" \
    "${ROOT_DIR}/scripts/build-xindex-llvm.sh"
  cp "${HOTSET_CONFIG_PATH}" "${BUILD_CONFIG_COPY}"
elif [[ ! -x "${HOTSET_BUILD_DIR}/ycsb_bench-native" || \
        ! -x "${HOTSET_BUILD_DIR}/ycsb_bench-arbiter" ]]; then
  echo "missing hot-set binaries under ${HOTSET_BUILD_DIR}; rerun with BUILD_BENCHMARKS=1" >&2
  exit 1
elif [[ ! -f "${BUILD_CONFIG_COPY}" ]] || ! cmp -s "${HOTSET_CONFIG_PATH}" "${BUILD_CONFIG_COPY}"; then
  echo "hot-set build config does not match ${HOTSET_CONFIG_PATH}; rebuild with BUILD_BENCHMARKS=1" >&2
  exit 1
fi

REPORT_CSV="${HOTSET_BUILD_DIR}/ycsb_bench.hotset-sites.csv"
EFFECTIVE_ARGS="${HOTSET_BUILD_DIR}/ycsb_bench.hotset-effective.opt-args"
if [[ ! -s "${REPORT_CSV}" || ! -s "${EFFECTIVE_ARGS}" ]]; then
  echo "missing hot-set decision artifacts under ${HOTSET_BUILD_DIR}" >&2
  exit 1
fi

SELECTED_SEEDS="$(awk -F, 'NR > 1 && $10 == "seed" && $12 == "yes" {count++} END {print count + 0}' "${REPORT_CSV}")"
SELECTED_MEMBERS="$(awk -F, 'NR > 1 && $10 == "member" && $12 == "yes" {count++} END {print count + 0}' "${REPORT_CSV}")"
SELECTED_SEED_FUNCTIONS="$(awk -F, 'NR > 1 && $10 == "seed" && $12 == "yes" {print $3}' "${REPORT_CSV}")"

if [[ -n "${EXPECTED_SEED_COUNT}" && "${SELECTED_SEEDS}" != "${EXPECTED_SEED_COUNT}" ]]; then
  echo "hot-set config expected ${EXPECTED_SEED_COUNT} seed(s), selected ${SELECTED_SEEDS}" >&2
  exit 1
fi
if [[ -n "${EXPECTED_MEMBER_COUNT}" && "${SELECTED_MEMBERS}" != "${EXPECTED_MEMBER_COUNT}" ]]; then
  echo "hot-set config expected ${EXPECTED_MEMBER_COUNT} member(s), selected ${SELECTED_MEMBERS}" >&2
  exit 1
fi
if [[ -n "${EXPECTED_SEED_FUNCTION}" && "${SELECTED_SEED_FUNCTIONS}" != "${EXPECTED_SEED_FUNCTION}" ]]; then
  echo "hot-set config expected seed function ${EXPECTED_SEED_FUNCTION}, selected: ${SELECTED_SEED_FUNCTIONS:-none}" >&2
  exit 1
fi

mkdir -p "${RESULT_DIR}/logs"
if [[ -e "${RESULT_DIR}/runs.csv" ]]; then
  echo "result file already exists: ${RESULT_DIR}/runs.csv" >&2
  echo "set RESULT_DIR to a new directory for an independent run" >&2
  exit 1
fi

cp "${HOTSET_CONFIG_PATH}" "${RESULT_DIR}/hotset-input.config"
cp "${REPORT_CSV}" "${RESULT_DIR}/hotset-sites.csv"
cp "${EFFECTIVE_ARGS}" "${RESULT_DIR}/hotset-effective.opt-args"
CONFIG_SHA256="$(sha256sum "${HOTSET_CONFIG_PATH}" | awk '{print $1}')"
sha256sum \
  "${HOTSET_BUILD_DIR}/ycsb_bench-native" \
  "${HOTSET_BUILD_DIR}/ycsb_bench-arbiter" \
  > "${RESULT_DIR}/binaries.sha256"

RUNS_CSV="${RESULT_DIR}/runs.csv"
printf 'benchmark,workload,config,repeat,mode,binary,target_node,cpu_node,mem_node,threads,iteration,config_sha256,time_sec,throughput,max_rss_kb,wall_time,swaps,log,time_log,status,heap_backend,allocation_node,arena_slab_bytes,arena_reserve_bytes,arena_slot_alignment,arena_allocations,arena_peak_live,arena_assigned_bytes,arena_fallbacks,duration_seconds,arena_resident_bytes,arena_majority_node,arena_query_error_pages,throughput_sample_seconds\n' > "${RUNS_CSV}"
SAMPLES_CSV="${RESULT_DIR}/throughput-samples.csv"
printf 'benchmark,workload,config,repeat,mode,elapsed_sec,interval_sec,interval_ops,interval_ops_per_sec,cumulative_ops,cumulative_ops_per_sec,final,log\n' > "${SAMPLES_CSV}"
FAILURES=0

run_one() {
  local workload="$1"
  local config="$2"
  local repeat="$3"
  local mode="$4"
  local binary="$5"
  local load_path="${XINDEX_SCALE_DATA_DIR}/xindex_load_ycsb_${workload}.dat"
  local tx_path="${XINDEX_SCALE_DATA_DIR}/xindex_transaction_ycsb_${workload}.dat"
  local log="${RESULT_DIR}/logs/xindex_${workload}_${config}_r${repeat}.log"
  local time_log="${RESULT_DIR}/logs/xindex_${workload}_${config}_r${repeat}.time"
  local -a env_args=(
    "YCSB_TYPE=${workload}"
    "XINDEX_FG=${XINDEX_FG}"
    "XINDEX_ITERATION=${XINDEX_ITERATION}"
    "XINDEX_DURATION_SECONDS=${XINDEX_DURATION_SECONDS}"
    "XINDEX_THROUGHPUT_SAMPLE_SECONDS=${XINDEX_THROUGHPUT_SAMPLE_SECONDS}"
    "YCSB_LOAD_PATH=${load_path}"
    "YCSB_TX_PATH=${tx_path}"
    "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
    "XINDEX_BG=${XINDEX_BG}"
  )
  local rc time_sec throughput max_rss wall_time swaps status
  local allocator allocation_node arena_allocations arena_peak_live
  local arena_assigned_bytes arena_fallbacks arena_report_node
  local arena_resident_bytes arena_majority_node arena_query_error_pages

  if [[ "${workload}" != "a" && ! -f "${load_path}" ]]; then
    load_path="${XINDEX_SCALE_DATA_DIR}/xindex_load_ycsb_a.dat"
    env_args[4]="YCSB_LOAD_PATH=${load_path}"
  fi

  if [[ "${mode}" == "native" ]]; then
    env_args+=("NATIVE_XINDEX_BIN=${binary}")
    allocator=native
    allocation_node="${MEM_NODE}"
  else
    allocator="${HEAP_BACKEND}"
    env_args+=(
      "ARBITER_XINDEX_BIN=${binary}"
      "ARBITER_HEAP_BACKEND=${HEAP_BACKEND}"
      "ARBITER_ARENA_SLAB_BYTES=${ARENA_SLAB_BYTES}"
      "ARBITER_ARENA_RESERVE_BYTES=${ARENA_RESERVE_BYTES}"
      "ARBITER_ARENA_SLOT_ALIGNMENT=${ARENA_SLOT_ALIGNMENT}"
      "ARBITER_ARENA_STRICT=${ARENA_STRICT}"
      "ARBITER_ARENA_REPORT=${ARENA_REPORT}"
    )
  fi
  if [[ "${mode}" == "local" ]]; then
    allocation_node="${MEM_NODE}"
    env_args+=("ARBITER_LOCAL_NODE=${MEM_NODE}")
  fi
  if [[ "${mode}" == "remote" ]]; then
    allocation_node="${TARGET_NODE}"
    env_args+=("ARBITER_TARGET_NODE=${TARGET_NODE}")
  fi

  echo "[run] workload=${workload} config=${config} repeat=${repeat}"
  set +e
  /usr/bin/time -v -o "${time_log}" \
    numactl --cpunodebind="${CPU_NODE}" --membind="${MEM_NODE}" \
    env "${env_args[@]}" \
    "${ROOT_DIR}/scripts/run-xindex-arbiter.sh" "${mode}" \
    > "${log}" 2>&1
  rc=$?
  set -e

  time_sec="$(awk -F': ' '/\[ycsb\] Time\(sec\)/ {v=$NF} END {print v}' "${log}")"
  throughput="$(awk -F': ' '/\[ycsb\] Throughput\(op\/s\)/ {v=$NF} END {print v}' "${log}")"
  max_rss="$(awk -F': ' '/Maximum resident set size/ {print $2}' "${time_log}")"
  wall_time="$(awk -F': ' '/Elapsed \(wall clock\) time/ {print $2}' "${time_log}")"
  swaps="$(awk -F': ' '/Swaps/ {print $2}' "${time_log}")"
  arena_allocations=""
  arena_peak_live=""
  arena_assigned_bytes=""
  arena_fallbacks=""
  arena_report_node=""
  arena_resident_bytes=""
  arena_majority_node=""
  arena_query_error_pages=""
  if [[ "${mode}" != "native" && "${HEAP_BACKEND}" == "arena" ]]; then
    arena_report_node="$(awk '/^arbiter-arena-summary / {for (i=1; i<=NF; i++) if ($i ~ /^node=/) {split($i, a, "="); v=a[2]}} END {print v}' "${log}")"
    arena_allocations="$(awk '/^arbiter-arena-summary / {for (i=1; i<=NF; i++) if ($i ~ /^allocations=/) {split($i, a, "="); v=a[2]}} END {print v}' "${log}")"
    arena_peak_live="$(awk '/^arbiter-arena-summary / {for (i=1; i<=NF; i++) if ($i ~ /^peak_live=/) {split($i, a, "="); v=a[2]}} END {print v}' "${log}")"
    arena_assigned_bytes="$(awk '/^arbiter-arena-summary / {for (i=1; i<=NF; i++) if ($i ~ /^assigned_bytes=/) {split($i, a, "="); v=a[2]}} END {print v}' "${log}")"
    arena_fallbacks="$(awk '/^arbiter-arena-summary / {for (i=1; i<=NF; i++) if ($i ~ /^fallback_allocations=/) {split($i, a, "="); v=a[2]}} END {print v}' "${log}")"
    arena_resident_bytes="$(awk '/^arbiter-arena-residency / {for (i=1; i<=NF; i++) if ($i ~ /^resident_bytes=/) {split($i, a, "="); v=a[2]}} END {print v}' "${log}")"
    arena_majority_node="$(awk '/^arbiter-arena-residency / {for (i=1; i<=NF; i++) if ($i ~ /^majority_node=/) {split($i, a, "="); v=a[2]}} END {print v}' "${log}")"
    arena_query_error_pages="$(awk '/^arbiter-arena-residency / {for (i=1; i<=NF; i++) if ($i ~ /^query_error_pages=/) {split($i, a, "="); v=a[2]}} END {print v}' "${log}")"
  fi
  status=ok
  if [[ "${rc}" -ne 0 ]]; then
    status="failed:${rc}"
  elif [[ -z "${time_sec}" || -z "${throughput}" || -z "${max_rss}" ]]; then
    status=parse-failed
  elif [[ "${mode}" != "native" && "${HEAP_BACKEND}" == "arena" && \
          ( -z "${arena_report_node}" || -z "${arena_allocations}" || \
            -z "${arena_fallbacks}" || -z "${arena_resident_bytes}" || \
            -z "${arena_majority_node}" || \
            -z "${arena_query_error_pages}" ) ]]; then
    status=arena-report-missing
  elif [[ "${mode}" != "native" && "${HEAP_BACKEND}" == "arena" && \
          "${arena_report_node}" != "${allocation_node}" ]]; then
    status="arena-node-mismatch:${arena_report_node}"
  elif [[ "${mode}" != "native" && "${HEAP_BACKEND}" == "arena" && \
          "${arena_fallbacks}" != "0" ]]; then
    status="arena-fallback:${arena_fallbacks}"
  elif [[ "${mode}" != "native" && "${HEAP_BACKEND}" == "arena" && \
          "${arena_query_error_pages}" != "0" ]]; then
    status="arena-placement-query-error:${arena_query_error_pages}"
  elif [[ "${mode}" != "native" && "${HEAP_BACKEND}" == "arena" && \
          "${arena_majority_node}" != "${allocation_node}" ]]; then
    status="arena-residency-node-mismatch:${arena_majority_node}"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    xindex "${workload}" "${config}" "${repeat}" "${mode}" "${binary}" \
    "${TARGET_NODE}" "${CPU_NODE}" "${MEM_NODE}" "${XINDEX_FG}" \
    "${XINDEX_ITERATION}" "${CONFIG_SHA256}" "${time_sec}" "${throughput}" \
    "${max_rss}" "${wall_time}" "${swaps}" "${log}" "${time_log}" "${status}" \
    "${allocator}" "${allocation_node}" "${ARENA_SLAB_BYTES}" \
    "${ARENA_RESERVE_BYTES}" "${ARENA_SLOT_ALIGNMENT}" \
    "${arena_allocations}" "${arena_peak_live}" "${arena_assigned_bytes}" \
    "${arena_fallbacks}" "${XINDEX_DURATION_SECONDS}" \
    "${arena_resident_bytes}" "${arena_majority_node}" \
    "${arena_query_error_pages}" "${XINDEX_THROUGHPUT_SAMPLE_SECONDS}" \
    >> "${RUNS_CSV}"

  awk -v benchmark=xindex -v workload="${workload}" -v config="${config}" \
      -v repeat="${repeat}" -v mode="${mode}" -v log_path="${log}" '
    /\[ycsb\] Throughput sample / && / elapsed_sec=/ {
      delete value
      for (i = 1; i <= NF; ++i) {
        if ($i ~ /^[a-z_]+=/) {
          split($i, field, "=")
          value[field[1]] = field[2]
        }
      }
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
             benchmark, workload, config, repeat, mode,
             value["elapsed_sec"], value["interval_sec"],
             value["interval_ops"], value["interval_ops_per_sec"],
             value["cumulative_ops"], value["cumulative_ops_per_sec"],
             value["final"], log_path
    }
  ' "${log}" >> "${SAMPLES_CSV}"

  if [[ "${status}" == "ok" ]]; then
    echo "[done] workload=${workload} config=${config} time=${time_sec} throughput=${throughput} max_rss_kb=${max_rss}"
  else
    echo "[fail] workload=${workload} config=${config} status=${status}"
    FAILURES=$((FAILURES + 1))
    if [[ "${FAIL_FAST}" == "1" ]]; then
      echo "FAIL_FAST=1: stopping after the first failed run" >&2
      exit 1
    fi
  fi

  if [[ "${COOLDOWN_SECONDS}" -gt 0 ]]; then
    echo "[cooldown] ${COOLDOWN_SECONDS} seconds"
    sleep "${COOLDOWN_SECONDS}"
  fi
}

for workload in ${YCSB_TYPES}; do
  for repeat in $(seq 1 "${REPEATS}"); do
    if [[ "${RUN_NATIVE}" == "1" ]]; then
      run_one "${workload}" native "${repeat}" native "${HOTSET_BUILD_DIR}/ycsb_bench-native"
    fi
    target_first=0
    if [[ "${FIRST_PLACEMENT}" == "target" ]]; then
      target_first=1
    fi
    if [[ "${ALTERNATE_PLACEMENT_ORDER}" == "1" && $((repeat % 2)) -eq 0 ]]; then
      target_first=$((1 - target_first))
    fi
    if [[ "${target_first}" == "1" ]]; then
      if [[ "${RUN_TARGET}" == "1" ]]; then
        run_one "${workload}" hotset-use-target "${repeat}" remote "${HOTSET_BUILD_DIR}/ycsb_bench-arbiter"
      fi
      if [[ "${RUN_LOCAL}" == "1" ]]; then
        run_one "${workload}" hotset-use-local "${repeat}" local "${HOTSET_BUILD_DIR}/ycsb_bench-arbiter"
      fi
    else
      if [[ "${RUN_LOCAL}" == "1" ]]; then
        run_one "${workload}" hotset-use-local "${repeat}" local "${HOTSET_BUILD_DIR}/ycsb_bench-arbiter"
      fi
      if [[ "${RUN_TARGET}" == "1" ]]; then
        run_one "${workload}" hotset-use-target "${repeat}" remote "${HOTSET_BUILD_DIR}/ycsb_bench-arbiter"
      fi
    fi
  done
done

SUMMARY_CSV="${RESULT_DIR}/summary.csv"
printf 'benchmark,workload,config,metric,repeats,avg_time_sec,avg_throughput,avg_max_rss_kb\n' > "${SUMMARY_CSV}"
for workload in ${YCSB_TYPES}; do
  for config in native hotset-use-local hotset-use-target; do
    awk -F, -v workload="${workload}" -v config="${config}" '
      NR > 1 && $2 == workload && $3 == config && $20 == "ok" {
        count++
        time += $13
        throughput += $14
        rss += $15
      }
      END {
        if (count > 0)
          printf "xindex,%s,%s,op/s,%d,%.9g,%.9g,%.9g\n", workload,
                 config, count, time / count, throughput / count, rss / count
      }
    ' "${RUNS_CSV}" >> "${SUMMARY_CSV}"
  done
done

SUMMARY_MD="${RESULT_DIR}/summary.md"
{
  echo "# Protected XIndex Hot-Set Experiment"
  echo
  echo "- Config: \`${HOTSET_CONFIG_PATH}\`"
  echo "- Config SHA-256: \`${CONFIG_SHA256}\`"
  echo "- Selected sites: ${SELECTED_SEEDS} seeds, ${SELECTED_MEMBERS} members"
  echo "- Scale: ${LOAD_RECORDS} load records, ${TX_OPS} transaction operations"
  echo "- Workloads: \`${YCSB_TYPES}\`"
  echo "- Repeats: ${REPEATS}"
  echo "- Foreground threads: ${XINDEX_FG}"
  echo "- Background threads: ${XINDEX_BG}"
  echo "- Iterations: ${XINDEX_ITERATION}"
  echo "- Duration seconds (0 means iteration mode): ${XINDEX_DURATION_SECONDS}"
  echo "- Throughput sample seconds: ${XINDEX_THROUGHPUT_SAMPLE_SECONDS}"
  echo "- Alternate local/target order: ${ALTERNATE_PLACEMENT_ORDER}"
  echo "- First placement: ${FIRST_PLACEMENT}"
  echo "- Cooldown seconds after each row: ${COOLDOWN_SECONDS}"
  echo "- CPU node: ${CPU_NODE}"
  echo "- Baseline memory node: ${MEM_NODE}"
  echo "- Target memory node: ${TARGET_NODE:-disabled}"
  echo "- Hot-set heap backend: ${HEAP_BACKEND}"
  if [[ "${HEAP_BACKEND}" == "arena" ]]; then
    echo "- Arena slab bytes: ${ARENA_SLAB_BYTES}"
    echo "- Arena reserve/capacity bytes: ${ARENA_RESERVE_BYTES}"
    echo "- Arena slot alignment: ${ARENA_SLOT_ALIGNMENT}"
    echo "- Arena strict/no-fallback: ${ARENA_STRICT}"
  fi
  echo "- Protection: MemoryMax=${MEMORY_MAX}, MemorySwapMax=${MEMORY_SWAP_MAX}"
  echo
  echo "| Workload | Config | Repeats | Avg time (s) | Avg throughput (op/s) | Avg max RSS (KiB) |"
  echo "|---|---|---:|---:|---:|---:|"
  awk -F, 'NR > 1 {printf "| %s | %s | %s | %s | %s | %s |\n", $2, $3, $5, $6, $7, $8}' "${SUMMARY_CSV}"
  echo
  echo "The local and target rows use the same rewritten hot-set binary and"
  echo "the same heap backend. The arena is bound to node ${MEM_NODE} for the"
  echo "local row and node ${TARGET_NODE:-disabled} for the target row."
} > "${SUMMARY_MD}"

cat <<EOF

Hot-set experiment complete.
Results:
  ${RUNS_CSV}
  ${SUMMARY_CSV}
  ${SUMMARY_MD}
  ${SAMPLES_CSV}
  ${RESULT_DIR}/hotset-input.config
  ${RESULT_DIR}/hotset-sites.csv
  ${RESULT_DIR}/hotset-effective.opt-args
EOF

if [[ "${FAILURES}" -ne 0 ]]; then
  echo "hot-set experiment recorded ${FAILURES} failed run(s)" >&2
  exit 1
fi
