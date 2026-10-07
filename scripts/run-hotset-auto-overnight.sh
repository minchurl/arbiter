#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=check

LOAD_RECORDS="${XINDEX_SCALE_LOAD_RECORDS:-20000000}"
TX_OPS="${XINDEX_SCALE_TX_OPS:-80000000}"
DURATION_SECONDS="${XINDEX_DURATION_SECONDS:-900}"
SOAK_DURATION_SECONDS="${XINDEX_SOAK_DURATION_SECONDS:-3600}"
SAMPLE_SECONDS="${XINDEX_THROUGHPUT_SAMPLE_SECONDS:-60}"
ROUNDS="${OVERNIGHT_ROUNDS:-7}"
SOAK_AFTER_ROUND="${SOAK_AFTER_ROUND:-6}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-5}"
XINDEX_FG="${XINDEX_FG:-31}"
XINDEX_BG="${XINDEX_BG:-1}"

CPU_NODE="${ARBITER_CPU_NODE:-0}"
MEM_NODE="${ARBITER_MEM_NODE:-0}"
TARGET_NODE="${ARBITER_TARGET_NODE:-2}"
MEMORY_MAX="${MEMORY_MAX:-40G}"
MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-0}"
ARENA_RESERVE_BYTES="${ARBITER_ARENA_RESERVE_BYTES:-4294967296}"
MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR:-/opt/intel/oneapi/mkl/2025.2/lib}"

SCALE_DATA_DIR="${XINDEX_SCALE_DATA_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_scale_${LOAD_RECORDS}_${TX_OPS}}"
FINALIST_CONFIG="${FINALIST_CONFIG:-${ROOT_DIR}/configs/hotset/xindex-cxl-arena-auto-k1-s13.config}"
FINALIST_BUILD_DIR="${FINALIST_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-hotset-auto-k1-s13}"

RUN_ID="${HOTSET_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/hotset-auto-overnight-${RUN_ID}}"
END_DEADLINE="${OVERNIGHT_END_DEADLINE:-2026-08-14 09:00:00}"

usage() {
  cat <<EOF
usage: $0 --check | --run

Checks or runs the selected XIndex hot-set confirmation:
  native baseline + automatic top-1 local/CXL pair + one-hour CXL soak

Defaults are 20M/80M, 31 foreground + 1 background worker, seven rounds, and
15 minutes per main row. Every round has three fresh-process rows: native,
automatic top-1 local, and automatic top-1 CXL. The first six rounds use all
six order permutations once. A 60-minute automatic top-1 CXL soak runs after
round 6, followed by round 7 as a post-soak sentinel.

The default measured time is 6.25 hours. Throughput is sampled every 60
seconds. The script refuses a schedule whose conservative estimate reaches
the 09:00 KST deadline. It never creates or manages tmux.
EOF
}

case "${1:-}" in
  --check|"") MODE=check ;;
  --run) MODE=run ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

require_positive_integer() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${name} must be a positive integer: ${value}" >&2
    exit 1
  fi
}

require_nonnegative_integer() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    echo "${name} must be a non-negative integer: ${value}" >&2
    exit 1
  fi
}

human_bytes() {
  numfmt --to=iec-i --suffix=B "$1"
}

set_round_order() {
  local round="$1"
  case $(((round - 1) % 6)) in
    0) ROW_ORDER=(native local cxl) ;;
    1) ROW_ORDER=(local cxl native) ;;
    2) ROW_ORDER=(cxl native local) ;;
    3) ROW_ORDER=(native cxl local) ;;
    4) ROW_ORDER=(cxl local native) ;;
    5) ROW_ORDER=(local native cxl) ;;
  esac
}

round_order_csv() {
  local round="$1" joined
  set_round_order "${round}"
  joined="$(IFS=,; echo "${ROW_ORDER[*]}")"
  printf '%s' "${joined}"
}

for command in awk cmp date grep lscpu numactl numfmt pgrep seq sha256sum systemd-run tee wc; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "missing required command: ${command}" >&2
    exit 1
  fi
done

require_positive_integer XINDEX_SCALE_LOAD_RECORDS "${LOAD_RECORDS}"
require_positive_integer XINDEX_SCALE_TX_OPS "${TX_OPS}"
require_positive_integer XINDEX_DURATION_SECONDS "${DURATION_SECONDS}"
require_positive_integer XINDEX_SOAK_DURATION_SECONDS "${SOAK_DURATION_SECONDS}"
require_positive_integer XINDEX_THROUGHPUT_SAMPLE_SECONDS "${SAMPLE_SECONDS}"
require_positive_integer OVERNIGHT_ROUNDS "${ROUNDS}"
require_positive_integer SOAK_AFTER_ROUND "${SOAK_AFTER_ROUND}"
require_nonnegative_integer COOLDOWN_SECONDS "${COOLDOWN_SECONDS}"
require_positive_integer XINDEX_FG "${XINDEX_FG}"
require_positive_integer XINDEX_BG "${XINDEX_BG}"
require_positive_integer ARBITER_ARENA_RESERVE_BYTES "${ARENA_RESERVE_BYTES}"

if [[ "${SAMPLE_SECONDS}" -ge "${DURATION_SECONDS}" ||
      "${SAMPLE_SECONDS}" -ge "${SOAK_DURATION_SECONDS}" ]]; then
  echo "sampling interval must be shorter than main and soak row durations" >&2
  exit 1
fi
if [[ "${SOAK_AFTER_ROUND}" -ge "${ROUNDS}" ]]; then
  echo "SOAK_AFTER_ROUND must leave at least one post-soak round" >&2
  exit 1
fi

for node in "${CPU_NODE}" "${MEM_NODE}" "${TARGET_NODE}"; do
  if [[ ! "${node}" =~ ^[0-9]+$ || ! -d "/sys/devices/system/node/node${node}" ]]; then
    echo "invalid NUMA node: ${node}" >&2
    exit 1
  fi
done

NODE_CPU_COUNT="$(lscpu -p=CPU,NODE | awk -F, -v node="${CPU_NODE}" '
  $1 !~ /^#/ && $2 == node {count++}
  END {print count + 0}
')"
if [[ "${XINDEX_FG}" -lt 24 ]]; then
  echo "XINDEX_FG=${XINDEX_FG} is below the 24-core coherence threshold" >&2
  exit 1
fi
if [[ $((XINDEX_FG + XINDEX_BG)) -gt "${NODE_CPU_COUNT}" ]]; then
  echo "foreground + background workers exceed node ${CPU_NODE} CPU count" >&2
  exit 1
fi

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

check_policy_build() {
  local label="$1" config="$2" build_dir="$3" expected_function="$4"
  local report selected_count selected_function

  if [[ ! -f "${config}" ]]; then
    echo "missing ${label} config: ${config}" >&2
    exit 1
  fi
  for binary in ycsb_bench-native ycsb_bench-arbiter; do
    if [[ ! -x "${build_dir}/${binary}" ]]; then
      echo "missing ${label} binary: ${build_dir}/${binary}" >&2
      exit 1
    fi
  done
  if [[ ! -f "${build_dir}/hotset-build.config" ]] ||
     ! cmp -s "${config}" "${build_dir}/hotset-build.config"; then
    echo "${label} binary/config mismatch: ${build_dir}" >&2
    exit 1
  fi

  report="${build_dir}/ycsb_bench.hotset-sites.csv"
  if [[ ! -s "${report}" || ! -s "${build_dir}/ycsb_bench.hotset-effective.opt-args" ]]; then
    echo "missing ${label} hot-set artifacts" >&2
    exit 1
  fi
  selected_count="$(awk -F, 'NR > 1 && $10 == "seed" && $12 == "yes" {count++} END {print count + 0}' "${report}")"
  selected_function="$(awk -F, 'NR > 1 && $10 == "seed" && $12 == "yes" {print $3}' "${report}")"
  if [[ "${selected_count}" != "1" || "${selected_function}" != "${expected_function}" ]]; then
    echo "${label} expected one ${expected_function} seed; got ${selected_count}: ${selected_function}" >&2
    exit 1
  fi
  if ! grep -a -q 'Throughput sample interval(sec)' "${build_dir}/ycsb_bench-arbiter"; then
    echo "${label} binary does not contain throughput sampling support" >&2
    exit 1
  fi
}

check_policy_build auto-k1 "${FINALIST_CONFIG}" "${FINALIST_BUILD_DIR}" insert_ptr

LOAD_TRACE="${SCALE_DATA_DIR}/xindex_load_ycsb_a.dat"
TX_TRACE="${SCALE_DATA_DIR}/xindex_transaction_ycsb_a.dat"
if [[ ! -s "${LOAD_TRACE}" || ! -s "${TX_TRACE}" ]]; then
  echo "missing validated 20M/80M scaled traces under ${SCALE_DATA_DIR}" >&2
  exit 1
fi
LOAD_LINES="$(wc -l < "${LOAD_TRACE}")"
TX_LINES="$(wc -l < "${TX_TRACE}")"
if [[ "${LOAD_LINES}" != "${LOAD_RECORDS}" || "${TX_LINES}" != "${TX_OPS}" ]]; then
  echo "scaled trace count mismatch: ${LOAD_LINES}/${TX_LINES}" >&2
  exit 1
fi

if pgrep -f '/ycsb_bench-(native|arbiter)( |$)' >/dev/null 2>&1; then
  echo "another XIndex benchmark is already running" >&2
  pgrep -af '/ycsb_bench-(native|arbiter)( |$)' >&2 || true
  exit 1
fi
if [[ -e "${RESULT_DIR}" ]]; then
  echo "result directory already exists: ${RESULT_DIR}" >&2
  exit 1
fi

ROWS_PER_ROUND=3
MAIN_ROWS=$((ROUNDS * ROWS_PER_ROUND))
SOAK_ROWS=1
TOTAL_ROWS=$((MAIN_ROWS + SOAK_ROWS))
MAIN_MEASURED_SECONDS=$((MAIN_ROWS * DURATION_SECONDS))
MEASURED_SECONDS=$((MAIN_MEASURED_SECONDS + SOAK_DURATION_SECONDS))
# Previous 20M/80M runs required about 13 seconds outside the measured region.
# Use 25 seconds per row plus the explicit cooldown as a conservative schedule.
ESTIMATED_SECONDS=$((MEASURED_SECONDS + TOTAL_ROWS * (25 + COOLDOWN_SECONDS)))
NOW_EPOCH="$(date +%s)"
ESTIMATED_END_EPOCH=$((NOW_EPOCH + ESTIMATED_SECONDS))
DEADLINE_EPOCH="$(date -d "${END_DEADLINE}" +%s)"
if [[ "${ESTIMATED_END_EPOCH}" -ge "${DEADLINE_EPOCH}" ]]; then
  echo "conservative estimated end $(date -d "@${ESTIMATED_END_EPOCH}" '+%F %T %Z') reaches deadline ${END_DEADLINE}" >&2
  exit 1
fi

cat <<EOF
Automatic hot-set overnight preflight passed.
  mode:                    ${MODE}
  policies:                native + auto-k1 local/CXL
  resolved auto-k1 seed:   insert_ptr
  scale:                   ${LOAD_RECORDS} / ${TX_OPS}
  main rounds / rows:      ${ROUNDS} / ${MAIN_ROWS}
  main duration per row:   ${DURATION_SECONDS} seconds
  CXL soak:                ${SOAK_DURATION_SECONDS} seconds after round ${SOAK_AFTER_ROUND}
  total rows:              ${TOTAL_ROWS}
  throughput sampling:     ${SAMPLE_SECONDS} seconds
  measured time:           $(awk -v s="${MEASURED_SECONDS}" 'BEGIN {printf "%.2f hours", s / 3600}')
  conservative wall time:  $(awk -v s="${ESTIMATED_SECONDS}" 'BEGIN {printf "%.2f hours", s / 3600}')
  estimated finish:        $(date -d "@${ESTIMATED_END_EPOCH}" '+%F %T %Z')
  required finish before:  ${END_DEADLINE} KST
  CPU / local / CXL node:  ${CPU_NODE} / ${MEM_NODE} / ${TARGET_NODE}
  foreground / background: ${XINDEX_FG} / ${XINDEX_BG}
  memory / swap limit:     ${MEMORY_MAX} / ${MEMORY_SWAP_MAX}
  arena capacity:          $(human_bytes "${ARENA_RESERVE_BYTES}")
  result:                  ${RESULT_DIR}
EOF
for round in $(seq 1 "${ROUNDS}"); do
  printf '  round %02d order:          %s\n' "${round}" "$(round_order_csv "${round}")"
  if [[ "${round}" -eq "${SOAK_AFTER_ROUND}" ]]; then
    printf '  after round %02d:         auto-k1 CXL soak (%ss)\n' "${round}" "${SOAK_DURATION_SECONDS}"
  fi
done

if [[ "${MODE}" == "check" ]]; then
  echo "check-only mode: no benchmark was started"
  exit 0
fi

mkdir -p "${RESULT_DIR}/artifacts/auto-k1"
cp "${FINALIST_CONFIG}" "${RESULT_DIR}/artifacts/auto-k1/input.config"
cp "${FINALIST_BUILD_DIR}/ycsb_bench.hotset-sites.csv" "${RESULT_DIR}/artifacts/auto-k1/hotset-sites.csv"
cp "${FINALIST_BUILD_DIR}/ycsb_bench.hotset-effective.opt-args" "${RESULT_DIR}/artifacts/auto-k1/effective.opt-args"
sha256sum \
  "${FINALIST_BUILD_DIR}/ycsb_bench-native" \
  "${FINALIST_BUILD_DIR}/ycsb_bench-arbiter" \
  > "${RESULT_DIR}/binaries.sha256"

cat > "${RESULT_DIR}/manifest.txt" <<EOF
started_at=$(date '+%F %T %Z')
rounds=${ROUNDS}
main_duration_seconds=${DURATION_SECONDS}
soak_duration_seconds=${SOAK_DURATION_SECONDS}
soak_after_round=${SOAK_AFTER_ROUND}
sample_seconds=${SAMPLE_SECONDS}
cooldown_seconds=${COOLDOWN_SECONDS}
load_records=${LOAD_RECORDS}
transaction_ops=${TX_OPS}
foreground=${XINDEX_FG}
background=${XINDEX_BG}
cpu_node=${CPU_NODE}
local_node=${MEM_NODE}
cxl_node=${TARGET_NODE}
memory_max=${MEMORY_MAX}
memory_swap_max=${MEMORY_SWAP_MAX}
arena_reserve_bytes=${ARENA_RESERVE_BYTES}
finalist_config=${FINALIST_CONFIG}
finalist_build_dir=${FINALIST_BUILD_DIR}
EOF
for round in $(seq 1 "${ROUNDS}"); do
  printf 'round_order_%s=%s\n' "${round}" "$(round_order_csv "${round}")" >> "${RESULT_DIR}/manifest.txt"
done

CONSOLE_LOG="${RESULT_DIR}/overnight-console.log"
COMBINED_RUNS="${RESULT_DIR}/runs.csv"
COMBINED_SAMPLES="${RESULT_DIR}/throughput-samples.csv"
printf 'phase,round,position,policy,benchmark,workload,config,repeat,mode,binary,target_node,cpu_node,mem_node,threads,iteration,config_sha256,time_sec,throughput,max_rss_kb,wall_time,swaps,log,time_log,status,heap_backend,allocation_node,arena_slab_bytes,arena_reserve_bytes,arena_slot_alignment,arena_allocations,arena_peak_live,arena_assigned_bytes,arena_fallbacks,duration_seconds,arena_resident_bytes,arena_majority_node,arena_query_error_pages,throughput_sample_seconds\n' > "${COMBINED_RUNS}"
printf 'phase,round,position,policy,benchmark,workload,config,repeat,mode,elapsed_sec,interval_sec,interval_ops,interval_ops_per_sec,cumulative_ops,cumulative_ops_per_sec,final,log\n' > "${COMBINED_SAMPLES}"

run_row() {
  local phase="$1" round_tag="$2" position="$3" mode="$4" duration="$5"
  local run_native=0 run_local=0 run_target=0 policy
  local row_dir driver_status row_count sample_count final_sample_count

  case "${mode}" in
    native)
      run_native=1
      policy=native
      ;;
    local)
      run_local=1
      policy=auto-k1
      ;;
    cxl)
      run_target=1
      policy=auto-k1
      ;;
    *)
      echo "invalid overnight row mode: ${mode}" >&2
      exit 1
      ;;
  esac

  row_dir="${RESULT_DIR}/${phase}/round-${round_tag}/row-$(printf '%02d' "${position}")-${policy}-${mode}"

  mkdir -p "$(dirname "${row_dir}")"
  echo "[${phase} round=${round_tag} position=${position}] ${policy}-${mode}, duration=${duration}s" | tee -a "${CONSOLE_LOG}"
  set +e
  env \
    RESULT_DIR="${row_dir}" \
    HOTSET_BUILD_DIR="${FINALIST_BUILD_DIR}" \
    XINDEX_SCALE_DATA_DIR="${SCALE_DATA_DIR}" \
    XINDEX_SCALE_LOAD_RECORDS="${LOAD_RECORDS}" \
    XINDEX_SCALE_TX_OPS="${TX_OPS}" \
    XINDEX_DURATION_SECONDS="${duration}" \
    XINDEX_THROUGHPUT_SAMPLE_SECONDS="${SAMPLE_SECONDS}" \
    XINDEX_FG="${XINDEX_FG}" \
    XINDEX_BG="${XINDEX_BG}" \
    YCSB_TYPES=a REPEATS=1 \
    ARBITER_CPU_NODE="${CPU_NODE}" \
    ARBITER_MEM_NODE="${MEM_NODE}" \
    ARBITER_TARGET_NODE="${TARGET_NODE}" \
    ARBITER_HEAP_BACKEND=arena \
    ARBITER_HOTSET_CONFIG="${FINALIST_CONFIG}" \
    ARBITER_ARENA_RESERVE_BYTES="${ARENA_RESERVE_BYTES}" \
    MEMORY_MAX="${MEMORY_MAX}" \
    MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX}" \
    RUN_NATIVE="${run_native}" \
    RUN_LOCAL="${run_local}" \
    RUN_TARGET="${run_target}" \
    FIRST_PLACEMENT=local \
    ALTERNATE_PLACEMENT_ORDER=0 \
    PREPARE_SCALE_DATA=0 \
    COOLDOWN_SECONDS="${COOLDOWN_SECONDS}" \
    BUILD_BENCHMARKS=0 \
    USE_SYSTEMD_SCOPE=1 \
    FAIL_FAST=1 \
    MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR}" \
    "${ROOT_DIR}/scripts/run-protected-hotset-experiment.sh" \
    2>&1 | tee -a "${CONSOLE_LOG}"
  driver_status=${PIPESTATUS[0]}
  set -e
  if [[ "${driver_status}" -ne 0 ]]; then
    echo "overnight row failed: phase=${phase} round=${round_tag} policy=${policy} mode=${mode} exit=${driver_status}" | tee -a "${CONSOLE_LOG}" >&2
    exit "${driver_status}"
  fi

  row_count="$(awk 'END {print NR - 1}' "${row_dir}/runs.csv")"
  sample_count="$(awk 'END {print NR - 1}' "${row_dir}/throughput-samples.csv")"
  final_sample_count="$(awk -F, 'NR > 1 && $12 == 1 {count++} END {print count + 0}' "${row_dir}/throughput-samples.csv")"
  if [[ "${row_count}" != "1" || "${final_sample_count}" != "1" ||
        "${sample_count}" != "$(((duration + SAMPLE_SECONDS - 1) / SAMPLE_SECONDS))" ]]; then
    echo "overnight row accounting failed: rows=${row_count} samples=${sample_count} final_samples=${final_sample_count}" | tee -a "${CONSOLE_LOG}" >&2
    exit 1
  fi

  awk -v phase="${phase}" -v round="${round_tag}" -v position="${position}" -v policy="${policy}" \
    'NR > 1 {print phase "," round "," position "," policy "," $0}' \
    "${row_dir}/runs.csv" >> "${COMBINED_RUNS}"
  awk -v phase="${phase}" -v round="${round_tag}" -v position="${position}" -v policy="${policy}" \
    'NR > 1 {print phase "," round "," position "," policy "," $0}' \
    "${row_dir}/throughput-samples.csv" >> "${COMBINED_SAMPLES}"
}

for round in $(seq 1 "${ROUNDS}"); do
  round_tag="$(printf '%02d' "${round}")"
  set_round_order "${round}"
  position=0
  for row_mode in "${ROW_ORDER[@]}"; do
    position=$((position + 1))
    run_row main "${round_tag}" "${position}" "${row_mode}" "${DURATION_SECONDS}"
  done

  if [[ "${round}" -eq "${SOAK_AFTER_ROUND}" ]]; then
    run_row soak "after-${round_tag}" 1 cxl "${SOAK_DURATION_SECONDS}"
  fi
done

cat <<EOF | tee -a "${CONSOLE_LOG}"
Automatic hot-set overnight experiment complete.
  main:    ${ROUNDS} balanced native/local/CXL rounds
  soak:    ${SOAK_DURATION_SECONDS}s auto-k1 CXL after round ${SOAK_AFTER_ROUND}
  runs:    ${COMBINED_RUNS}
  samples: ${COMBINED_SAMPLES}
  result:  ${RESULT_DIR}
EOF
