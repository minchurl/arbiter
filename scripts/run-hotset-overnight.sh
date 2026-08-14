#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="check"

# A 20%-of-full workload is deliberate. The full 100M/400M trace is not a
# safe unattended default with the current arena cap and node-0 footprint.
LOAD_RECORDS="${XINDEX_SCALE_LOAD_RECORDS:-20000000}"
TX_OPS="${XINDEX_SCALE_TX_OPS:-80000000}"
DURATION_SECONDS="${XINDEX_DURATION_SECONDS:-900}"
REPEATS="${REPEATS:-8}"
XINDEX_FG="${XINDEX_FG:-31}"
XINDEX_BG="${XINDEX_BG:-1}"
YCSB_TYPES="${YCSB_TYPES:-a}"

CPU_NODE="${ARBITER_CPU_NODE:-0}"
MEM_NODE="${ARBITER_MEM_NODE:-0}"
TARGET_NODE="${ARBITER_TARGET_NODE:-2}"
RUN_NATIVE="${RUN_NATIVE:-0}"
RUN_LOCAL="${RUN_LOCAL:-1}"
RUN_TARGET="${RUN_TARGET:-1}"

MEMORY_MAX="${MEMORY_MAX:-40G}"
MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-0}"
ARENA_RESERVE_BYTES="${ARBITER_ARENA_RESERVE_BYTES:-4294967296}"
HOTSET_CONFIG="${ARBITER_HOTSET_CONFIG:-configs/hotset/xindex-cxl-arena-site99-baseline.config}"
HOTSET_BUILD_DIR="${HOTSET_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-hotset-site99-baseline}"
SCALE_DATA_DIR="${XINDEX_SCALE_DATA_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_scale_${LOAD_RECORDS}_${TX_OPS}}"
MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR:-/opt/intel/oneapi/mkl/2025.2/lib}"
RUN_ID="${HOTSET_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/hotset-arena-overnight-${LOAD_RECORDS}-${TX_OPS}-${RUN_ID}}"
ALLOW_LARGE_SCALE="${HOTSET_ALLOW_LARGE_SCALE:-0}"

usage() {
  cat <<EOF
usage: $0 --check | --run

Preflights or runs a protected XIndex hot-set comparison. The default shape is
20M load / 80M transactions, 15 minutes per row, 8 repeats, and two paired
rows (local arena and CXL arena): exactly four hours of measured time. Local
and CXL order alternates on every repeat to reduce time/thermal-order bias.

The wall-clock duration is longer because every row reloads the trace and
rebuilds the index. The default result is expected to take roughly 4.3-5 hours.

Important overrides:
  RESULT_DIR                    unique output directory
  XINDEX_SCALE_LOAD_RECORDS     default: 20000000
  XINDEX_SCALE_TX_OPS           default: 80000000
  XINDEX_DURATION_SECONDS       default: 900
  REPEATS                       default: 8
  XINDEX_FG                     default: 31; one core remains for background
  XINDEX_BG                     default: 1
  ARBITER_TARGET_NODE           default: 2
  MEMORY_MAX                    default: 40G
  HOTSET_ALLOW_LARGE_SCALE      default: 0; required above 20M/80M

This script never creates or manages tmux itself. Use --check first, then run
it inside a detached tmux session with --run.
EOF
}

case "${1:-}" in
  --check|"") MODE="check" ;;
  --run) MODE="run" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

require_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${name} must be a positive integer: ${value}" >&2
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

human_bytes() {
  numfmt --to=iec-i --suffix=B "$1"
}

for command in awk cmp df lscpu numactl numfmt sha256sum systemd-run; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "missing required command: ${command}" >&2
    exit 1
  fi
done

require_positive_integer XINDEX_SCALE_LOAD_RECORDS "${LOAD_RECORDS}"
require_positive_integer XINDEX_SCALE_TX_OPS "${TX_OPS}"
require_positive_integer XINDEX_DURATION_SECONDS "${DURATION_SECONDS}"
require_positive_integer REPEATS "${REPEATS}"
require_positive_integer XINDEX_FG "${XINDEX_FG}"
require_positive_integer XINDEX_BG "${XINDEX_BG}"
require_positive_integer ARBITER_ARENA_RESERVE_BYTES "${ARENA_RESERVE_BYTES}"
require_toggle RUN_NATIVE "${RUN_NATIVE}"
require_toggle RUN_LOCAL "${RUN_LOCAL}"
require_toggle RUN_TARGET "${RUN_TARGET}"
require_toggle HOTSET_ALLOW_LARGE_SCALE "${ALLOW_LARGE_SCALE}"

ROW_COUNT=$((RUN_NATIVE + RUN_LOCAL + RUN_TARGET))
if [[ "${ROW_COUNT}" -eq 0 ]]; then
  echo "at least one of RUN_NATIVE, RUN_LOCAL, or RUN_TARGET must be 1" >&2
  exit 1
fi

if [[ "${YCSB_TYPES}" != "a" ]]; then
  echo "overnight safety profile currently requires YCSB_TYPES=a" >&2
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
if [[ ! "${TARGET_NODE}" =~ ^[0-9]+$ || ! -d "/sys/devices/system/node/node${TARGET_NODE}" ]]; then
  echo "invalid ARBITER_TARGET_NODE=${TARGET_NODE}" >&2
  exit 1
fi

NODE_CPU_COUNT="$(lscpu -p=CPU,NODE | awk -F, -v node="${CPU_NODE}" '
  $1 !~ /^#/ && $2 == node {count++}
  END {print count + 0}
')"
ACTIVE_WORKER_COUNT=$((XINDEX_FG + XINDEX_BG))
if [[ "${XINDEX_FG}" -lt 24 ]]; then
  echo "XINDEX_FG=${XINDEX_FG} is below the 24-core coherence threshold" >&2
  exit 1
fi
if [[ "${ACTIVE_WORKER_COUNT}" -gt "${NODE_CPU_COUNT}" ]]; then
  echo "foreground + background workers (${ACTIVE_WORKER_COUNT}) exceed node ${CPU_NODE} CPU count (${NODE_CPU_COUNT})" >&2
  exit 1
fi

if [[ "${RUN_TARGET}" == "1" ]]; then
  shopt -s nullglob
  dax_target_files=(/sys/bus/dax/devices/*/target_node)
  shopt -u nullglob
  cxl_target_found=0
  for target_file in "${dax_target_files[@]}"; do
    if [[ "$(<"${target_file}")" == "${TARGET_NODE}" ]]; then
      cxl_target_found=1
      break
    fi
  done
  if [[ "${cxl_target_found}" -ne 1 ]]; then
    echo "node ${TARGET_NODE} is not exposed as a device-dax target node" >&2
    exit 1
  fi
fi

if [[ "${ALLOW_LARGE_SCALE}" != "1" ]] &&
   { [[ "${LOAD_RECORDS}" -gt 20000000 ]] || [[ "${TX_OPS}" -gt 80000000 ]]; }; then
  cat >&2 <<EOF
refusing unattended scale ${LOAD_RECORDS}/${TX_OPS}
the unattended safety ceiling is 20M/80M; set HOTSET_ALLOW_LARGE_SCALE=1 only
after changing the memory and arena limits and validating a short pilot
EOF
  exit 1
fi

CONFIG_PATH="${HOTSET_CONFIG}"
if [[ "${CONFIG_PATH}" != /* ]]; then
  CONFIG_PATH="${ROOT_DIR}/${CONFIG_PATH}"
fi
if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "missing hot-set config: ${CONFIG_PATH}" >&2
  exit 1
fi

for binary in ycsb_bench-native ycsb_bench-arbiter; do
  if [[ ! -x "${HOTSET_BUILD_DIR}/${binary}" ]]; then
    echo "missing benchmark binary: ${HOTSET_BUILD_DIR}/${binary}" >&2
    echo "build it before starting the overnight run" >&2
    exit 1
  fi
done
if [[ ! -f "${HOTSET_BUILD_DIR}/hotset-build.config" ]] ||
   ! cmp -s "${CONFIG_PATH}" "${HOTSET_BUILD_DIR}/hotset-build.config"; then
  echo "benchmark binary was not built with ${CONFIG_PATH}" >&2
  exit 1
fi

LOAD_SOURCE="${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_a.dat"
TX_SOURCE="${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_a.dat"
for trace in "${LOAD_SOURCE}" "${TX_SOURCE}"; do
  if [[ ! -s "${trace}" ]]; then
    echo "missing full trace: ${trace}" >&2
    exit 1
  fi
done

MEMORY_MAX_BYTES="$(numfmt --from=iec "${MEMORY_MAX}")"
SCALE_FACTOR="$(awk -v load_count="${LOAD_RECORDS}" -v tx_count="${TX_OPS}" '
  BEGIN {
    load_factor = load_count / 1000000
    tx_factor = tx_count / 4000000
    printf "%.9f", (load_factor > tx_factor ? load_factor : tx_factor)
  }
')"
ESTIMATED_RSS_BYTES="$(awk -v factor="${SCALE_FACTOR}" '
  BEGIN {printf "%.0f", 1057848 * 1024 * factor}
')"
RSS_WITH_MARGIN_BYTES="$(awk -v bytes="${ESTIMATED_RSS_BYTES}" '
  BEGIN {printf "%.0f", bytes * 1.5}
')"
if [[ "${RSS_WITH_MARGIN_BYTES}" -gt "${MEMORY_MAX_BYTES}" ]]; then
  echo "conservative RSS estimate $(human_bytes "${RSS_WITH_MARGIN_BYTES}") exceeds MemoryMax=${MEMORY_MAX}" >&2
  exit 1
fi

ESTIMATED_ARENA_BYTES="$(awk -v load_count="${LOAD_RECORDS}" '
  BEGIN {printf "%.0f", 45745664 * load_count / 1000000}
')"
ARENA_WITH_MARGIN_BYTES=$((ESTIMATED_ARENA_BYTES * 2))
if [[ "${ARENA_WITH_MARGIN_BYTES}" -gt "${ARENA_RESERVE_BYTES}" ]]; then
  echo "arena estimate with 2x margin $(human_bytes "${ARENA_WITH_MARGIN_BYTES}") exceeds reserve $(human_bytes "${ARENA_RESERVE_BYTES}")" >&2
  exit 1
fi

LOAD_SOURCE_BYTES="$(stat -c %s "${LOAD_SOURCE}")"
TX_SOURCE_BYTES="$(stat -c %s "${TX_SOURCE}")"
ESTIMATED_TRACE_BYTES="$(awk \
  -v load_bytes="${LOAD_SOURCE_BYTES}" -v tx_bytes="${TX_SOURCE_BYTES}" \
  -v load_count="${LOAD_RECORDS}" -v tx_count="${TX_OPS}" '
  BEGIN {
    estimated = load_bytes * load_count / 100000000
    estimated += tx_bytes * tx_count / 400000000
    printf "%.0f", estimated
  }
')"
REQUIRED_DISK_BYTES=$((ESTIMATED_TRACE_BYTES * 2 + 1073741824))
AVAILABLE_DISK_BYTES="$(df --output=avail -B1 "${ROOT_DIR}" | tail -n 1 | tr -d ' ')"
if [[ "${REQUIRED_DISK_BYTES}" -gt "${AVAILABLE_DISK_BYTES}" ]]; then
  echo "estimated extraction space $(human_bytes "${REQUIRED_DISK_BYTES}") exceeds available disk $(human_bytes "${AVAILABLE_DISK_BYTES}")" >&2
  exit 1
fi

if pgrep -f '/ycsb_bench-(native|arbiter)( |$)' >/dev/null 2>&1; then
  echo "another XIndex benchmark process is already running" >&2
  pgrep -af '/ycsb_bench-(native|arbiter)( |$)' >&2 || true
  exit 1
fi

if [[ -e "${RESULT_DIR}/runs.csv" ]]; then
  echo "result already exists: ${RESULT_DIR}/runs.csv" >&2
  exit 1
fi

MEASURED_SECONDS=$((DURATION_SECONDS * REPEATS * ROW_COUNT))
MEASURED_HOURS="$(awk -v seconds="${MEASURED_SECONDS}" 'BEGIN {printf "%.2f", seconds / 3600}')"

cat <<EOF
Overnight hot-set preflight passed.
  mode:                    ${MODE}
  scale:                   ${LOAD_RECORDS} load / ${TX_OPS} transactions
  measured rows:           ${ROW_COUNT} per repeat
  duration per row:        ${DURATION_SECONDS} seconds
  repeats:                 ${REPEATS}
  total measured time:     ${MEASURED_HOURS} hours
  wall time note:          measured time plus trace/index setup per row
  CPU / local / CXL node:  ${CPU_NODE} / ${MEM_NODE} / ${TARGET_NODE}
  foreground / background: ${XINDEX_FG} / ${XINDEX_BG} (${ACTIVE_WORKER_COUNT} active workers on ${NODE_CPU_COUNT} cores)
  conservative RSS check:  $(human_bytes "${RSS_WITH_MARGIN_BYTES}") < ${MEMORY_MAX}
  arena estimate:          $(human_bytes "${ESTIMATED_ARENA_BYTES}")
  arena hard capacity:     $(human_bytes "${ARENA_RESERVE_BYTES}")
  extraction space check:  $(human_bytes "${REQUIRED_DISK_BYTES}") required, $(human_bytes "${AVAILABLE_DISK_BYTES}") available
  result:                   ${RESULT_DIR}
EOF

if [[ "${MODE}" == "check" ]]; then
  echo "check-only mode: no benchmark was started"
  exit 0
fi

mkdir -p "${RESULT_DIR}"
CONSOLE_LOG="${RESULT_DIR}/overnight-console.log"

set +e
env \
  RESULT_DIR="${RESULT_DIR}" \
  HOTSET_BUILD_DIR="${HOTSET_BUILD_DIR}" \
  XINDEX_SCALE_DATA_DIR="${SCALE_DATA_DIR}" \
  XINDEX_SCALE_LOAD_RECORDS="${LOAD_RECORDS}" \
  XINDEX_SCALE_TX_OPS="${TX_OPS}" \
  XINDEX_DURATION_SECONDS="${DURATION_SECONDS}" \
  XINDEX_FG="${XINDEX_FG}" \
  XINDEX_BG="${XINDEX_BG}" \
  YCSB_TYPES="${YCSB_TYPES}" \
  REPEATS="${REPEATS}" \
  ARBITER_CPU_NODE="${CPU_NODE}" \
  ARBITER_MEM_NODE="${MEM_NODE}" \
  ARBITER_TARGET_NODE="${TARGET_NODE}" \
  ARBITER_HEAP_BACKEND=arena \
  ARBITER_HOTSET_CONFIG="${CONFIG_PATH}" \
  ARBITER_ARENA_RESERVE_BYTES="${ARENA_RESERVE_BYTES}" \
  MEMORY_MAX="${MEMORY_MAX}" \
  MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX}" \
  RUN_NATIVE="${RUN_NATIVE}" \
  RUN_LOCAL="${RUN_LOCAL}" \
  RUN_TARGET="${RUN_TARGET}" \
  ALTERNATE_PLACEMENT_ORDER=1 \
  BUILD_BENCHMARKS=0 \
  USE_SYSTEMD_SCOPE=1 \
  FAIL_FAST=1 \
  MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR}" \
  "${ROOT_DIR}/scripts/run-protected-hotset-experiment.sh" \
  2>&1 | tee -a "${CONSOLE_LOG}"
driver_status=${PIPESTATUS[0]}
set -e

if [[ "${driver_status}" -ne 0 ]]; then
  echo "overnight hot-set experiment failed: exit ${driver_status}" >&2
fi
exit "${driver_status}"
