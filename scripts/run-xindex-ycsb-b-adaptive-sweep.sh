#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=check
case "${1:-}" in
  --check|"") MODE=check ;;
  --run) MODE=run ;;
  -h|--help)
    cat <<'EOF'
usage: scripts/run-xindex-ycsb-b-adaptive-sweep.sh --check | --run

Rebuilds the 100 archived broad-sweep parameter configurations with the
current seed-only compiler, screens them on full-trace YCSB-B, confirms the
top ten, and runs four full-trace A/B pairs for the top three.

Every benchmark row consumes its 400M-operation transaction trace exactly
once. There is no measured-duration cutoff and no per-row timeout.

Default schedule:
  build/static analysis:  all 100 archived parameter configs
  B screening:            one local/CXL pair per static-unique safe config
  B confirmation:         top 10, two additional pairs (three total)
  A/B final:              top 3, four fresh pairs per workload
  native reference:       four fresh rows per workload in the final stage
  workers:                31 foreground + 1 background
  CPU/local/CXL nodes:    0 / 0 / 2
  memory/swap hard cap:   64G / 0
  controller budget:      8 hours (admission only; running rows finish)

Useful overrides:
  HOTSET_TOP_CONFIRM      default 10
  HOTSET_TOP_FINAL        default 3
  HOTSET_CONFIG_DIR       directory containing raw-*.config
  OVERNIGHT_MAX_WALL_SECONDS
                          default 28800 (8 hours)
  RESULT_DIR              unique result directory

--check performs read-only validation and does not build or benchmark.
EOF
    exit 0
    ;;
  *) echo "usage: $0 --check | --run" >&2; exit 2 ;;
esac

CONFIG_DIR="${HOTSET_CONFIG_DIR:-${ROOT_DIR}/configs/hotset/search-spaces/xindex-broad-100}"
TOP_CONFIRM="${HOTSET_TOP_CONFIRM:-10}"
TOP_FINAL="${HOTSET_TOP_FINAL:-3}"
CONFIRM_EXTRA_PAIRS="${HOTSET_CONFIRM_EXTRA_PAIRS:-2}"
FINAL_ROUNDS="${HOTSET_FINAL_ROUNDS:-4}"
SCREEN_MIN_DELTA_PCT="${HOTSET_SCREEN_MIN_DELTA_PCT:--15}"
CONFIRM_MIN_DELTA_PCT="${HOTSET_CONFIRM_MIN_DELTA_PCT:--10}"
MAX_CONFIRM_PER_RUNTIME_FP="${HOTSET_MAX_CONFIRM_PER_RUNTIME_FINGERPRINT:-2}"
MAX_FINAL_PER_RUNTIME_FP="${HOTSET_MAX_FINAL_PER_RUNTIME_FINGERPRINT:-1}"
MAX_WALL_SECONDS="${OVERNIGHT_MAX_WALL_SECONDS:-28800}"
ROW_ADMISSION_BUDGET_SECONDS="${XINDEX_ROW_ADMISSION_BUDGET_SECONDS:-90}"
FINALIZE_RESERVE_SECONDS="${FINALIZE_RESERVE_SECONDS:-300}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-2}"

CPU_NODE="${ARBITER_CPU_NODE:-0}"
MEM_NODE="${ARBITER_MEM_NODE:-0}"
TARGET_NODE="${ARBITER_TARGET_NODE:-2}"
XINDEX_FG="${XINDEX_FG:-31}"
XINDEX_BG="${XINDEX_BG:-1}"
MEMORY_MAX="${MEMORY_MAX:-64G}"
MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-0}"
ARENA_SLAB_BYTES="${ARBITER_ARENA_SLAB_BYTES:-2097152}"
ARENA_RESERVE_BYTES="${ARBITER_ARENA_RESERVE_BYTES:-25769803776}"
ARENA_SLOT_ALIGNMENT="${ARBITER_ARENA_SLOT_ALIGNMENT:-64}"

DATA_DIR="${XINDEX_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"
LOAD_TRACE="${DATA_DIR}/xindex_load_ycsb_a.dat"
TX_A_TRACE="${DATA_DIR}/xindex_transaction_ycsb_a.dat"
TX_B_TRACE="${DATA_DIR}/xindex_transaction_ycsb_b.dat"
EXPECTED_LOAD_BYTES=5388149510
EXPECTED_TX_A_BYTES=21757793131
EXPECTED_TX_B_BYTES=21937780070

ARBITER_BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"
CLANGXX="${CLANGXX:-${ROOT_DIR}/.tools/llvm-18.1.8/bin/clang++}"
OPT="${OPT:-${ROOT_DIR}/.tools/llvm18-apt-root/usr/bin/opt-18}"
PLUGIN="${ARBITER_LLVM_PLUGIN:-${ARBITER_BUILD_DIR}/lib/ArbiterLLVMPlugin.so}"
RUNTIME_LIB="${ARBITER_RUNTIME_LIB:-${ARBITER_BUILD_DIR}/runtime/libarbiter_runtime.a}"
LLVM_SHARED_LIB_DIR="${LLVM_SHARED_LIB_DIR:-${ROOT_DIR}/.tools/libllvm18-root/usr/lib/x86_64-linux-gnu}"
LLVM_TINFO_LIB_DIR="${LLVM_TINFO_LIB_DIR:-${ROOT_DIR}/.tools/libtinfo5-root/lib/x86_64-linux-gnu}"
CLANG_STDCXX_LIB_DIR="${CLANG_STDCXX_LIB_DIR:-${ROOT_DIR}/.tools/libstdcxx}"
CLANG_CXX_INCLUDE_ROOT="${CLANG_CXX_INCLUDE_ROOT:-/usr/include/c++/11}"
CLANG_CXX_TARGET_INCLUDE="${CLANG_CXX_TARGET_INCLUDE:-/usr/include/x86_64-linux-gnu/c++/11}"
LLVM_TOOL_LD_LIBRARY_PATH="${LLVM_SHARED_LIB_DIR}:${LLVM_TINFO_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
LLVM_TOOL_LIBRARY_PATH="${CLANG_STDCXX_LIB_DIR}${LIBRARY_PATH:+:${LIBRARY_PATH}}"
LLVM_TOOL_CPLUS_INCLUDE_PATH="${CLANG_CXX_INCLUDE_ROOT}:${CLANG_CXX_TARGET_INCLUDE}:${CLANG_CXX_INCLUDE_ROOT}/backward${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"

for mkl_root in /opt/intel/oneapi/mkl/latest /opt/intel/oneapi/mkl/2025.2 /opt/intel/oneapi/2025.2; do
  if [[ -f "${mkl_root}/include/mkl.h" && -f "${mkl_root}/lib/libmkl_rt.so" ]]; then
    MKL_INCLUDE_DIR="${MKL_INCLUDE_DIR:-${mkl_root}/include}"
    MKL_LINK_DIR="${MKL_LINK_DIR:-${mkl_root}/lib}"
    MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR:-${mkl_root}/lib}"
    break
  fi
done
MKL_INCLUDE_DIR="${MKL_INCLUDE_DIR:-}"
MKL_LINK_DIR="${MKL_LINK_DIR:-}"
MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR:-}"

RUN_ID="${HOTSET_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-ycsb-b-sweep-${RUN_ID}}"

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

require_number() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
    echo "${name} must be numeric: ${value}" >&2
    exit 1
  fi
}

for item in \
  "TOP_CONFIRM:${TOP_CONFIRM}" "TOP_FINAL:${TOP_FINAL}" \
  "CONFIRM_EXTRA_PAIRS:${CONFIRM_EXTRA_PAIRS}" "FINAL_ROUNDS:${FINAL_ROUNDS}" \
  "MAX_CONFIRM_PER_RUNTIME_FP:${MAX_CONFIRM_PER_RUNTIME_FP}" \
  "MAX_FINAL_PER_RUNTIME_FP:${MAX_FINAL_PER_RUNTIME_FP}" \
  "MAX_WALL_SECONDS:${MAX_WALL_SECONDS}" \
  "ROW_ADMISSION_BUDGET_SECONDS:${ROW_ADMISSION_BUDGET_SECONDS}" \
  "FINALIZE_RESERVE_SECONDS:${FINALIZE_RESERVE_SECONDS}" \
  "XINDEX_FG:${XINDEX_FG}" "ARENA_SLAB_BYTES:${ARENA_SLAB_BYTES}" \
  "ARENA_RESERVE_BYTES:${ARENA_RESERVE_BYTES}" \
  "ARENA_SLOT_ALIGNMENT:${ARENA_SLOT_ALIGNMENT}"; do
  require_positive_integer "${item%%:*}" "${item#*:}"
done
require_nonnegative_integer XINDEX_BG "${XINDEX_BG}"
require_nonnegative_integer COOLDOWN_SECONDS "${COOLDOWN_SECONDS}"
require_number SCREEN_MIN_DELTA_PCT "${SCREEN_MIN_DELTA_PCT}"
require_number CONFIRM_MIN_DELTA_PCT "${CONFIRM_MIN_DELTA_PCT}"

if [[ "${TOP_FINAL}" -gt "${TOP_CONFIRM}" ]]; then
  echo "HOTSET_TOP_FINAL cannot exceed HOTSET_TOP_CONFIRM" >&2
  exit 1
fi
if [[ "${MEMORY_MAX}" != 64G || "${MEMORY_SWAP_MAX}" != 0 ]]; then
  echo "reviewed protection requires MEMORY_MAX=64G and MEMORY_SWAP_MAX=0" >&2
  exit 1
fi
if [[ "${ARENA_RESERVE_BYTES}" -gt 34359738368 ]]; then
  echo "arena reserve exceeds the reviewed 32GiB ceiling" >&2
  exit 1
fi

for command in awk basename cat cmp cp date df find git head ldd lscpu mkdir \
  numactl paste pgrep realpath sed seq sha256sum sort stat systemd-run tee wc; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "missing required command: ${command}" >&2
    exit 1
  fi
done

for path in "${CLANGXX}" "${OPT}" "${PLUGIN}" "${RUNTIME_LIB}" \
  "${ROOT_DIR}/scripts/build-xindex-llvm.sh" \
  "${ROOT_DIR}/scripts/run-protected-hotset-experiment.sh"; do
  if [[ ! -s "${path}" ]]; then
    echo "missing required build artifact: ${path}" >&2
    exit 1
  fi
done
if [[ ! -f "${MKL_INCLUDE_DIR}/mkl.h" || ! -f "${MKL_LINK_DIR}/libmkl_rt.so" ]]; then
  echo "missing Intel MKL" >&2
  exit 1
fi

CLANG_MAJOR="$(env LD_LIBRARY_PATH="${LLVM_TOOL_LD_LIBRARY_PATH}" "${CLANGXX}" --version | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+[.]/) {split($i,v,"."); print v[1]; exit}}')"
OPT_MAJOR="$(env LD_LIBRARY_PATH="${LLVM_TOOL_LD_LIBRARY_PATH}" "${OPT}" --version | awk '/LLVM version/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+[.]/) {split($i,v,"."); print v[1]; exit}}')"
if [[ "${CLANG_MAJOR}" != 18 || "${OPT_MAJOR}" != 18 ]]; then
  echo "LLVM 18 is required; clang=${CLANG_MAJOR:-unknown}, opt=${OPT_MAJOR:-unknown}" >&2
  exit 1
fi
if ldd "${PLUGIN}" | awk '/not found/ {bad=1} END {exit bad ? 0 : 1}'; then
  echo "Arbiter LLVM plugin has unresolved libraries" >&2
  ldd "${PLUGIN}" >&2
  exit 1
fi

for node in "${CPU_NODE}" "${MEM_NODE}" "${TARGET_NODE}"; do
  if [[ ! "${node}" =~ ^[0-9]+$ || ! -d "/sys/devices/system/node/node${node}" ]]; then
    echo "invalid NUMA node: ${node}" >&2
    exit 1
  fi
done
if [[ "${TARGET_NODE}" == "${MEM_NODE}" ]]; then
  echo "local and CXL nodes must differ" >&2
  exit 1
fi
NODE_CPU_COUNT="$(lscpu -p=CPU,NODE | awk -F, -v node="${CPU_NODE}" '$1 !~ /^#/ && $2 == node {n++} END {print n+0}')"
if [[ $((XINDEX_FG + XINDEX_BG)) -gt "${NODE_CPU_COUNT}" ]]; then
  echo "workers exceed node ${CPU_NODE} CPU count (${NODE_CPU_COUNT})" >&2
  exit 1
fi
TARGET_MEMORY_KB="$(awk '/MemTotal/ {print $4}' "/sys/devices/system/node/node${TARGET_NODE}/meminfo")"
if [[ -z "${TARGET_MEMORY_KB}" || "${TARGET_MEMORY_KB}" -eq 0 ]]; then
  echo "target node ${TARGET_NODE} has no memory" >&2
  exit 1
fi

for trace in "${LOAD_TRACE}" "${TX_A_TRACE}" "${TX_B_TRACE}"; do
  if [[ ! -s "${trace}" ]]; then
    echo "missing full trace: ${trace}" >&2
    exit 1
  fi
done
LOAD_BYTES="$(stat -c %s "${LOAD_TRACE}")"
TX_A_BYTES="$(stat -c %s "${TX_A_TRACE}")"
TX_B_BYTES="$(stat -c %s "${TX_B_TRACE}")"
if [[ "${LOAD_BYTES}" != "${EXPECTED_LOAD_BYTES}" || \
      "${TX_A_BYTES}" != "${EXPECTED_TX_A_BYTES}" || \
      "${TX_B_BYTES}" != "${EXPECTED_TX_B_BYTES}" ]]; then
  echo "full-trace size mismatch: ${LOAD_BYTES}/${TX_A_BYTES}/${TX_B_BYTES}" >&2
  exit 1
fi

shopt -s nullglob
CONFIG_PATHS=("${CONFIG_DIR}"/raw-*.config)
shopt -u nullglob
CONFIG_COUNT="${#CONFIG_PATHS[@]}"
if [[ "${CONFIG_COUNT}" -ne 100 ]]; then
  echo "expected 100 raw configs under ${CONFIG_DIR}; found ${CONFIG_COUNT}" >&2
  exit 1
fi
if [[ -e "${RESULT_DIR}" ]]; then
  echo "result directory already exists: ${RESULT_DIR}" >&2
  exit 1
fi
if pgrep -af '[y]csb_bench' >/dev/null 2>&1; then
  echo "another ycsb_bench process is running" >&2
  pgrep -af '[y]csb_bench' >&2 || true
  exit 1
fi

FREE_BYTES="$(df -B1 --output=avail "${ROOT_DIR}" | awk 'NR == 2 {print $1}')"
if [[ "${FREE_BYTES}" -lt 8589934592 ]]; then
  echo "less than 8GiB free disk space" >&2
  exit 1
fi

MAX_SCREEN_ROWS=$((CONFIG_COUNT * 2))
MAX_CONFIRM_ROWS=$((TOP_CONFIRM * CONFIRM_EXTRA_PAIRS * 2))
MAX_FINAL_ROWS=$((TOP_FINAL * FINAL_ROUNDS * 2 * 2))
NATIVE_ROWS=$((FINAL_ROUNDS * 2))
MAX_ROWS=$((MAX_SCREEN_ROWS + MAX_CONFIRM_ROWS + MAX_FINAL_ROWS + NATIVE_ROWS))
ESTIMATED_SECONDS=$((MAX_ROWS * ROW_ADMISSION_BUDGET_SECONDS + 600))

cat <<EOF
XIndex/YCSB-B adaptive sweep preflight passed.
  mode:                         ${MODE}
  raw configs:                  ${CONFIG_COUNT}
  screen:                       B, one one-pass local/CXL pair
  confirmation:                 top ${TOP_CONFIRM}, ${CONFIRM_EXTRA_PAIRS} additional B pair(s)
  final:                        top ${TOP_FINAL}, ${FINAL_ROUNDS} fresh A/B pair(s)
  native final references:      ${FINAL_ROUNDS} per workload
  maximum rows before de-dup:   ${MAX_ROWS}
  estimated upper-bound time:   $(awk -v s="${ESTIMATED_SECONDS}" 'BEGIN {printf "%.2f hours", s/3600}')
  controller admission budget:  $(awk -v s="${MAX_WALL_SECONDS}" 'BEGIN {printf "%.2f hours", s/3600}')
  execution mode:               iteration=1, duration=0 (400M ops once)
  workers:                      ${XINDEX_FG} foreground + ${XINDEX_BG} background
  CPU / local / CXL node:       ${CPU_NODE} / ${MEM_NODE} / ${TARGET_NODE}
  memory / swap cap:            ${MEMORY_MAX} / ${MEMORY_SWAP_MAX}
  arena reserve:                ${ARENA_RESERVE_BYTES} bytes
  trace bytes load/A/B:         ${LOAD_BYTES} / ${TX_A_BYTES} / ${TX_B_BYTES}
  cache policy:                 fresh process; warm filesystem cache; no drop_caches
  free disk:                    ${FREE_BYTES} bytes
  result:                       ${RESULT_DIR}
EOF
if [[ "${MODE}" == check ]]; then
  echo "check-only mode: no result directory, build, or benchmark was started"
  exit 0
fi

mkdir -p "${RESULT_DIR}/builds" "${RESULT_DIR}/build-logs" "${RESULT_DIR}/rows"
CONSOLE_LOG="${RESULT_DIR}/sweep-console.log"
exec > >(tee -a "${CONSOLE_LOG}") 2>&1

START_EPOCH="$(date +%s)"
STOP_EPOCH=$((START_EPOCH + MAX_WALL_SECONDS))
MANIFEST="${RESULT_DIR}/manifest.txt"
BUILDS_CSV="${RESULT_DIR}/builds.csv"
SELECTED_CSV="${RESULT_DIR}/selected-configs.csv"
SELECTED_LIST="${RESULT_DIR}/selected-configs.txt"
OBSERVATIONS="${RESULT_DIR}/observations.csv"

cat >"${MANIFEST}" <<EOF
schema_version=1
started_at=$(date --iso-8601=seconds)
git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD)
git_branch=$(git -C "${ROOT_DIR}" branch --show-current)
git_dirty_files=$(git -C "${ROOT_DIR}" status --porcelain | wc -l)
controller=$(realpath "$0")
config_dir=${CONFIG_DIR}
raw_config_count=${CONFIG_COUNT}
screen_workload=b
top_confirm=${TOP_CONFIRM}
top_final=${TOP_FINAL}
confirm_extra_pairs=${CONFIRM_EXTRA_PAIRS}
final_rounds=${FINAL_ROUNDS}
execution_mode=iteration
iteration=1
duration_seconds=0
foreground=${XINDEX_FG}
background=${XINDEX_BG}
cpu_node=${CPU_NODE}
local_node=${MEM_NODE}
cxl_node=${TARGET_NODE}
memory_max=${MEMORY_MAX}
memory_swap_max=${MEMORY_SWAP_MAX}
arena_slab_bytes=${ARENA_SLAB_BYTES}
arena_reserve_bytes=${ARENA_RESERVE_BYTES}
arena_slot_alignment=${ARENA_SLOT_ALIGNMENT}
max_wall_seconds=${MAX_WALL_SECONDS}
stop_epoch=${STOP_EPOCH}
cache_policy=fresh process per row; filesystem page cache not dropped; CPU cache not flushed
EOF
git -C "${ROOT_DIR}" status --short >"${RESULT_DIR}/git-status-at-start.txt" || true
cp "$0" "${RESULT_DIR}/controller.sh"

printf 'candidate,design,status,static_fingerprint,selected_sites,config_path,build_dir,build_log\n' >"${BUILDS_CSV}"
printf 'candidate,design,static_fingerprint,selected_sites,config_path,build_dir\n' >"${SELECTED_CSV}"
: >"${SELECTED_LIST}"
printf 'phase,candidate,workload,replicate,position,requested_mode,actual_mode,status,throughput,time_sec,max_rss_kb,wall_time,swaps,arena_allocations,arena_peak_live,arena_assigned_bytes,arena_fallbacks,arena_resident_bytes,arena_majority_node,arena_query_error_pages,runtime_fingerprint,static_fingerprint,result_dir,driver_exit\n' >"${OBSERVATIONS}"

build_env=(
  "ARBITER_BUILD_DIR=${ARBITER_BUILD_DIR}"
  "ARBITER_LLVM_PLUGIN=${PLUGIN}"
  "ARBITER_RUNTIME_LIB=${RUNTIME_LIB}"
  "CLANGXX=${CLANGXX}" "OPT=${OPT}"
  "LD_LIBRARY_PATH=${LLVM_TOOL_LD_LIBRARY_PATH}"
  "LIBRARY_PATH=${LLVM_TOOL_LIBRARY_PATH}"
  "CPLUS_INCLUDE_PATH=${LLVM_TOOL_CPLUS_INCLUDE_PATH}"
  "MKL_INCLUDE_DIR=${MKL_INCLUDE_DIR}"
  "MKL_LINK_DIR=${MKL_LINK_DIR}"
)

NATIVE_BUILD_DIR="${RESULT_DIR}/builds/native"
NATIVE_BUILD_LOG="${RESULT_DIR}/build-logs/native.log"
echo "[build] common native binary"
env "${build_env[@]}" \
  ARBITER_BENCH_BUILD_DIR="${NATIVE_BUILD_DIR}" \
  ARBITER_HOTSET_CONFIG="${ROOT_DIR}/configs/hotset/candidates/raw-046.config" \
  ARBITER_BUILD_XINDEX_NATIVE=1 \
  "${ROOT_DIR}/scripts/build-xindex-llvm.sh" >"${NATIVE_BUILD_LOG}" 2>&1
if [[ ! -x "${NATIVE_BUILD_DIR}/ycsb_bench-native" ]]; then
  echo "native build failed; see ${NATIVE_BUILD_LOG}" >&2
  exit 1
fi
cp "${ROOT_DIR}/configs/hotset/candidates/raw-046.config" \
  "${NATIVE_BUILD_DIR}/hotset-build.config"

declare -A SEEN_STATIC=()
BUILD_FAILURES=0
UNSAFE_BUILDS=0
DUPLICATE_BUILDS=0
SELECTED_COUNT=0
for config in "${CONFIG_PATHS[@]}"; do
  candidate="$(basename "${config}" .config)"
  design="$(awk '/^# search_seed=/ {for (i=1; i<=NF; i++) if ($i ~ /^design=/) {sub(/^design=/,"",$i); print $i; exit}}' "${config}")"
  design="${design:-unknown}"
  build_dir="${RESULT_DIR}/builds/${candidate}"
  build_log="${RESULT_DIR}/build-logs/${candidate}.log"
  echo "[build] ${candidate} design=${design}"
  set +e
  env "${build_env[@]}" \
    ARBITER_BENCH_BUILD_DIR="${build_dir}" \
    ARBITER_HOTSET_CONFIG="${config}" \
    ARBITER_BUILD_XINDEX_NATIVE=0 \
    "${ROOT_DIR}/scripts/build-xindex-llvm.sh" >"${build_log}" 2>&1
  build_rc=$?
  set -e
  report="${build_dir}/ycsb_bench.hotset-sites.csv"
  if [[ "${build_rc}" -ne 0 || ! -x "${build_dir}/ycsb_bench-arbiter" || ! -s "${report}" ]]; then
    printf '%s,%s,build-failed:%s,,,,%s,%s\n' "${candidate}" "${design}" "${build_rc}" "${build_dir}" "${build_log}" >>"${BUILDS_CSV}"
    BUILD_FAILURES=$((BUILD_FAILURES + 1))
    continue
  fi
  cp "${NATIVE_BUILD_DIR}/ycsb_bench-native" "${build_dir}/ycsb_bench-native"
  cp "${config}" "${build_dir}/hotset-build.config"
  nonconstant="$(awk -F, 'NR > 1 && $12 == "yes" && $7 !~ /^[0-9]+$/ {print $1}' "${report}" | sort -n -u | paste -sd+ -)"
  static_fp="$(awk -F, 'NR > 1 && $12 == "yes" {print $1}' "${report}" | sort -n -u | paste -sd+ -)"
  selected_sites="$(awk -F, 'NR > 1 && $12 == "yes" {n++} END {print n+0}' "${report}")"
  if [[ -n "${nonconstant}" ]]; then
    status="unsafe-nonconstant:${nonconstant}"
    UNSAFE_BUILDS=$((UNSAFE_BUILDS + 1))
  elif [[ -z "${static_fp}" ]]; then
    status=no-selected-sites
  elif [[ -n "${SEEN_STATIC[${static_fp}]:-}" ]]; then
    status="duplicate-static:${SEEN_STATIC[${static_fp}]}"
    DUPLICATE_BUILDS=$((DUPLICATE_BUILDS + 1))
  else
    status=selected
    SEEN_STATIC["${static_fp}"]="${candidate}"
    SELECTED_COUNT=$((SELECTED_COUNT + 1))
    printf '%s,%s,%s,%s,%s,%s\n' "${candidate}" "${design}" "${static_fp}" "${selected_sites}" "${config}" "${build_dir}" >>"${SELECTED_CSV}"
    printf '%s\n' "${candidate}" >>"${SELECTED_LIST}"
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "${candidate}" "${design}" "${status}" "${static_fp}" "${selected_sites}" "${config}" "${build_dir}" "${build_log}" >>"${BUILDS_CSV}"
done

echo "[build-done] selected=${SELECTED_COUNT} duplicate=${DUPLICATE_BUILDS} unsafe=${UNSAFE_BUILDS} failed=${BUILD_FAILURES}"
printf 'selected_static_unique=%s\nduplicate_static=%s\nunsafe_builds=%s\nbuild_failures=%s\n' \
  "${SELECTED_COUNT}" "${DUPLICATE_BUILDS}" "${UNSAFE_BUILDS}" "${BUILD_FAILURES}" >>"${MANIFEST}"
if [[ "${SELECTED_COUNT}" -eq 0 ]]; then
  echo "no safe static-unique config was built" >&2
  exit 1
fi

declare -A C_CONFIG=() C_BUILD=() C_STATIC=()
mapfile -t SELECTED_IDS <"${SELECTED_LIST}"
while IFS=, read -r candidate design static_fp selected_sites config build_dir; do
  [[ "${candidate}" == candidate ]] && continue
  C_CONFIG["${candidate}"]="${config}"
  C_BUILD["${candidate}"]="${build_dir}"
  C_STATIC["${candidate}"]="${static_fp}"
done <"${SELECTED_CSV}"

ROW_SEQUENCE=0
PAIR_SEQUENCE=0
TIME_EXHAUSTED=0

can_start_block() {
  local rows="$1" now required
  now="$(date +%s)"
  required=$((rows * ROW_ADMISSION_BUDGET_SECONDS + FINALIZE_RESERVE_SECONDS))
  if [[ $((now + required)) -gt "${STOP_EPOCH}" ]]; then
    TIME_EXHAUSTED=1
    echo "[budget] not starting ${rows} row(s); remaining=$((STOP_EPOCH-now))s, estimated-required=${required}s"
    return 1
  fi
}

runtime_fingerprint() {
  local log="$1" fp
  fp="$(awk '
    /^arbiter-arena-site / {
      site=""; allocations=0
      for (i=1; i<=NF; i++) {
        if ($i ~ /^site=/) {split($i,a,"="); site=a[2]}
        if ($i ~ /^allocations=/) {split($i,a,"="); allocations=a[2]}
      }
      if (site != "" && allocations+0 > 0) print site
    }
  ' "${log}" 2>/dev/null | sort -n -u | paste -sd+ -)"
  printf '%s' "${fp:-none}"
}

append_failed_row() {
  local phase="$1" candidate="$2" workload="$3" replicate="$4" mode="$5"
  local status="$6" row_dir="$7" driver_rc="$8" static_fp="$9"
  printf '%s,%s,%s,%s,%s,%s,,%s,,,,,,,,,,,,,none,%s,%s,%s\n' \
    "${phase}" "${candidate}" "${workload}" "${replicate}" "${ROW_SEQUENCE}" \
    "${mode}" "${status}" "${static_fp}" "${row_dir}" "${driver_rc}" >>"${OBSERVATIONS}"
}

run_row() {
  local phase="$1" candidate="$2" workload="$3" replicate="$4" requested_mode="$5"
  local config build_dir static_fp run_native=0 run_local=0 run_target=0
  local row_dir driver_rc runs_count log runtime_fp
  if [[ "${candidate}" == native ]]; then
    config="${ROOT_DIR}/configs/hotset/candidates/raw-046.config"
    build_dir="${NATIVE_BUILD_DIR}"
    static_fp=native
  else
    config="${C_CONFIG[${candidate}]}"
    build_dir="${C_BUILD[${candidate}]}"
    static_fp="${C_STATIC[${candidate}]}"
  fi
  case "${requested_mode}" in
    native) run_native=1 ;;
    local) run_local=1 ;;
    cxl) run_target=1 ;;
    *) echo "invalid mode: ${requested_mode}" >&2; exit 1 ;;
  esac
  ROW_SEQUENCE=$((ROW_SEQUENCE + 1))
  row_dir="${RESULT_DIR}/rows/$(printf '%03d' "${ROW_SEQUENCE}")-${phase}-${candidate}-${workload}-r$(printf '%02d' "${replicate}")-${requested_mode}"
  echo "[row ${ROW_SEQUENCE}] phase=${phase} candidate=${candidate} workload=${workload} replicate=${replicate} mode=${requested_mode}"
  set +e
  env \
    RESULT_DIR="${row_dir}" HOTSET_BUILD_DIR="${build_dir}" \
    XINDEX_SCALE_DATA_DIR="${DATA_DIR}" \
    XINDEX_SCALE_LOAD_RECORDS=100000000 XINDEX_SCALE_TX_OPS=400000000 \
    XINDEX_ITERATION=1 XINDEX_DURATION_SECONDS=0 \
    XINDEX_THROUGHPUT_SAMPLE_SECONDS=0 \
    XINDEX_FG="${XINDEX_FG}" XINDEX_BG="${XINDEX_BG}" \
    YCSB_TYPES="${workload}" REPEATS=1 \
    ARBITER_CPU_NODE="${CPU_NODE}" ARBITER_MEM_NODE="${MEM_NODE}" \
    ARBITER_TARGET_NODE="${TARGET_NODE}" ARBITER_HOTSET_CONFIG="${config}" \
    ARBITER_HEAP_BACKEND=arena ARBITER_ARENA_SLAB_BYTES="${ARENA_SLAB_BYTES}" \
    ARBITER_ARENA_RESERVE_BYTES="${ARENA_RESERVE_BYTES}" \
    ARBITER_ARENA_SLOT_ALIGNMENT="${ARENA_SLOT_ALIGNMENT}" \
    ARBITER_ARENA_STRICT=1 ARBITER_ARENA_REPORT=1 \
    MEMORY_MAX="${MEMORY_MAX}" MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX}" \
    RUN_NATIVE="${run_native}" RUN_LOCAL="${run_local}" RUN_TARGET="${run_target}" \
    BUILD_BENCHMARKS=0 PREPARE_SCALE_DATA=0 FAIL_FAST=1 \
    FIRST_PLACEMENT=local ALTERNATE_PLACEMENT_ORDER=0 COOLDOWN_SECONDS=0 \
    USE_SYSTEMD_SCOPE=1 MKL_INCLUDE_DIR="${MKL_INCLUDE_DIR}" \
    MKL_LINK_DIR="${MKL_LINK_DIR}" MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR}" \
    LD_LIBRARY_PATH="${MKL_RUNTIME_DIR}" \
    "${ROOT_DIR}/scripts/run-protected-hotset-experiment.sh"
  driver_rc=$?
  set -e

  runs_count=0
  if [[ -s "${row_dir}/runs.csv" ]]; then
    runs_count="$(awk 'END {print (NR > 0 ? NR-1 : 0)}' "${row_dir}/runs.csv")"
  fi
  if [[ "${runs_count}" -ne 1 ]]; then
    append_failed_row "${phase}" "${candidate}" "${workload}" "${replicate}" \
      "${requested_mode}" "row-accounting-${runs_count}" "${row_dir}" "${driver_rc}" "${static_fp}"
    return
  fi
  log="$(awk -F, 'NR == 2 {print $18}' "${row_dir}/runs.csv")"
  if [[ "${requested_mode}" == native ]]; then runtime_fp=native; else runtime_fp="$(runtime_fingerprint "${log}")"; fi
  awk -F, -v OFS=, \
    -v phase="${phase}" -v candidate="${candidate}" -v workload="${workload}" \
    -v replicate="${replicate}" -v position="${ROW_SEQUENCE}" \
    -v requested="${requested_mode}" -v runtime_fp="${runtime_fp}" \
    -v static_fp="${static_fp}" -v result_dir="${row_dir}" -v driver_rc="${driver_rc}" '
      NR == 2 {
        row_status=$20
        if (driver_rc != 0 && row_status == "ok") row_status="driver-exit:" driver_rc
        print phase,candidate,workload,replicate,position,requested,$5,row_status,$14,$13,
              $15,$16,$17,$26,$27,$28,$29,$31,$32,$33,runtime_fp,static_fp,
              result_dir,driver_rc
      }
    ' "${row_dir}/runs.csv" >>"${OBSERVATIONS}"
  status="$(awk -F, 'END {print $8}' "${OBSERVATIONS}")"
  throughput="$(awk -F, 'END {print $9}' "${OBSERVATIONS}")"
  echo "[row-done] status=${status} throughput=${throughput:-none} runtime_sites=${runtime_fp} exit=${driver_rc}"
  if [[ "${COOLDOWN_SECONDS}" -gt 0 ]]; then sleep "${COOLDOWN_SECONDS}"; fi
}

run_pair() {
  local phase="$1" candidate="$2" workload="$3" replicate="$4" order
  if ! can_start_block 2; then return 1; fi
  if [[ $((PAIR_SEQUENCE % 2)) -eq 0 ]]; then order="local cxl"; else order="cxl local"; fi
  PAIR_SEQUENCE=$((PAIR_SEQUENCE + 1))
  for mode in ${order}; do
    run_row "${phase}" "${candidate}" "${workload}" "${replicate}" "${mode}"
  done
}

write_screen_summary() {
  awk -F, -v OFS=, -v local_node="${MEM_NODE}" -v cxl_node="${TARGET_NODE}" '
    NR > 1 && $1 == "screen" && $3 == "b" {
      c=$2; m=$6
      if (!(c in seen)) {seen[c]=1; order[++n]=c}
      status[c,m]=$8; ops[c,m]=$9+0; rss[c,m]=$11+0; swaps[c,m]=$13
      alloc[c,m]=$14; fallback[c,m]=$17; resident[c,m]=$18+0
      majority[c,m]=$19; query[c,m]=$20; fp[c,m]=$21; static[c]=$22
    }
    END {
      print "candidate,safe,reason,local_status,cxl_status,local_ops,cxl_ops,cxl_over_local_pct,runtime_fingerprint,static_fingerprint,cxl_resident_bytes,local_allocations,cxl_allocations,max_rss_kb"
      for (i=1; i<=n; i++) {
        c=order[i]; safe=1; reason="ok"; runtime=fp[c,"local"]
        if (status[c,"local"] != "ok" || status[c,"cxl"] != "ok") {safe=0; reason="row-status"}
        else if (fp[c,"local"] == "" || fp[c,"local"] == "none" || fp[c,"local"] != fp[c,"cxl"]) {safe=0; reason="runtime-fingerprint"}
        else if (swaps[c,"local"] != "0" || swaps[c,"cxl"] != "0") {safe=0; reason="swap"}
        else if (fallback[c,"local"] != "0" || fallback[c,"cxl"] != "0") {safe=0; reason="arena-fallback"}
        else if (query[c,"local"] != "0" || query[c,"cxl"] != "0") {safe=0; reason="placement-query"}
        else if (majority[c,"local"] != local_node || majority[c,"cxl"] != cxl_node) {safe=0; reason="placement-node"}
        else if (ops[c,"local"] <= 0 || ops[c,"cxl"] <= 0) {safe=0; reason="throughput"}
        delta=(ops[c,"local"] > 0 ? 100*(ops[c,"cxl"]/ops[c,"local"]-1) : 0)
        maxrss=(rss[c,"local"] > rss[c,"cxl"] ? rss[c,"local"] : rss[c,"cxl"])
        print c,safe,reason,status[c,"local"],status[c,"cxl"],ops[c,"local"],ops[c,"cxl"],delta,runtime,static[c],resident[c,"cxl"],alloc[c,"local"],alloc[c,"cxl"],maxrss
      }
    }
  ' "${OBSERVATIONS}" >"${RESULT_DIR}/screen-summary.csv"
}

write_screen_ranking() {
  awk -F, -v floor="${SCREEN_MIN_DELTA_PCT}" 'NR > 1 && $2 == 1 && $8+0 >= floor {print $1 "," $8 "," $9}' \
    "${RESULT_DIR}/screen-summary.csv" | sort -t, -k2,2nr -k1,1 >"${RESULT_DIR}/screen-eligible.tmp"
  awk -F, -v cap="${MAX_CONFIRM_PER_RUNTIME_FP}" 'seen[$3] < cap {seen[$3]++; print}' \
    "${RESULT_DIR}/screen-eligible.tmp" >"${RESULT_DIR}/screen-ranked.tmp"
  { echo 'rank,candidate,cxl_over_local_pct,runtime_fingerprint'; awk -F, -v OFS=, '{print NR,$1,$2,$3}' "${RESULT_DIR}/screen-ranked.tmp"; } >"${RESULT_DIR}/screen-ranking.csv"
  awk -F, -v limit="${TOP_CONFIRM}" 'NR > 1 && n < limit {print $2; n++}' "${RESULT_DIR}/screen-ranking.csv" >"${RESULT_DIR}/promoted-confirm.txt"
}

write_confirm_summary() {
  if [[ ! -s "${RESULT_DIR}/promoted-confirm.txt" ]]; then
    echo 'candidate,safe,reason,pairs,mean_local_ops,mean_cxl_ops,mean_paired_delta_pct,stddev_paired_delta_pct,cxl_wins,runtime_fingerprint,mean_cxl_resident_bytes,mean_local_rss_kb,mean_cxl_rss_kb' >"${RESULT_DIR}/confirm-summary.csv"
    return
  fi
  awk -F, -v OFS=, -v expected="$((CONFIRM_EXTRA_PAIRS + 1))" \
    -v local_node="${MEM_NODE}" -v cxl_node="${TARGET_NODE}" '
    FNR == NR {if ($1 != "") {want[$1]=1; order[++n]=$1}; next}
    FNR > 1 && ($1 == "screen" || $1 == "confirm") && $3 == "b" && ($2 in want) {
      c=$2; r=$4+0; m=$6; key=c SUBSEP r
      rows[c,m]++; status[c,m,r]=$8; ops[key,m]=$9+0
      if ($8 != "ok" || $13 != "0" || $17 != "0" || $20 != "0") bad[c]=1
      if ((m == "local" && $19 != local_node) || (m == "cxl" && $19 != cxl_node)) bad[c]=1
      if ($21 == "" || $21 == "none") bad[c]=1
      if (!(c in fp)) fp[c]=$21; else if (fp[c] != $21) bad[c]=1
      resident[c,m]+=$18+0; rss[c,m]+=$11+0
    }
    END {
      print "candidate,safe,reason,pairs,mean_local_ops,mean_cxl_ops,mean_paired_delta_pct,stddev_paired_delta_pct,cxl_wins,runtime_fingerprint,mean_cxl_resident_bytes,mean_local_rss_kb,mean_cxl_rss_kb"
      for (i=1; i<=n; i++) {
        c=order[i]; pairs=0; sl=0; sc=0; sd=0; sd2=0; wins=0
        for (r=1; r<=expected; r++) {
          key=c SUBSEP r
          if (ops[key,"local"] > 0 && ops[key,"cxl"] > 0) {
            d=100*(ops[key,"cxl"]/ops[key,"local"]-1); pairs++; sl+=ops[key,"local"]; sc+=ops[key,"cxl"]; sd+=d; sd2+=d*d; if (d>0) wins++
          }
        }
        safe=(pairs == expected && !bad[c]); reason=(safe ? "ok" : (pairs != expected ? "incomplete" : "unsafe-row"))
        md=(pairs ? sd/pairs : 0); variance=(pairs>1 ? (sd2-sd*sd/pairs)/(pairs-1) : 0); if (variance<0) variance=0
        print c,safe,reason,pairs,(pairs?sl/pairs:0),(pairs?sc/pairs:0),md,sqrt(variance),wins,fp[c],(rows[c,"cxl"]?resident[c,"cxl"]/rows[c,"cxl"]:0),(rows[c,"local"]?rss[c,"local"]/rows[c,"local"]:0),(rows[c,"cxl"]?rss[c,"cxl"]/rows[c,"cxl"]:0)
      }
    }
  ' "${RESULT_DIR}/promoted-confirm.txt" "${OBSERVATIONS}" >"${RESULT_DIR}/confirm-summary.csv"
}

write_confirm_ranking() {
  awk -F, -v floor="${CONFIRM_MIN_DELTA_PCT}" 'NR > 1 && $2 == 1 && $7+0 >= floor {print $1 "," $7 "," $10}' \
    "${RESULT_DIR}/confirm-summary.csv" | sort -t, -k2,2nr -k1,1 >"${RESULT_DIR}/confirm-eligible.tmp"
  awk -F, -v cap="${MAX_FINAL_PER_RUNTIME_FP}" 'seen[$3] < cap {seen[$3]++; print}' \
    "${RESULT_DIR}/confirm-eligible.tmp" >"${RESULT_DIR}/confirm-ranked.tmp"
  { echo 'rank,candidate,mean_paired_delta_pct,runtime_fingerprint'; awk -F, -v OFS=, '{print NR,$1,$2,$3}' "${RESULT_DIR}/confirm-ranked.tmp"; } >"${RESULT_DIR}/confirm-ranking.csv"
  awk -F, -v limit="${TOP_FINAL}" 'NR > 1 && n < limit {print $2; n++}' "${RESULT_DIR}/confirm-ranking.csv" >"${RESULT_DIR}/finalists.txt"
}

write_final_summary() {
  printf 'candidate,workload,safe,reason,pairs,mean_local_ops,mean_cxl_ops,mean_paired_delta_pct,stddev_paired_delta_pct,cxl_wins,runtime_fingerprint,mean_cxl_resident_bytes,mean_local_rss_kb,mean_cxl_rss_kb\n' >"${RESULT_DIR}/final-summary.csv"
  if [[ -s "${RESULT_DIR}/finalists.txt" ]]; then
    for workload in a b; do
      awk -F, -v OFS=, -v expected="${FINAL_ROUNDS}" -v workload="${workload}" \
      -v local_node="${MEM_NODE}" -v cxl_node="${TARGET_NODE}" '
      FNR == NR {if ($1 != "") {want[$1]=1; order[++n]=$1}; next}
      FNR > 1 && $1 == "final" && $3 == workload && ($2 in want) {
        c=$2; r=$4+0; m=$6; key=c SUBSEP r
        rows[c,m]++; ops[key,m]=$9+0
        if ($8 != "ok" || $13 != "0" || $17 != "0" || $20 != "0") bad[c]=1
        if ((m == "local" && $19 != local_node) || (m == "cxl" && $19 != cxl_node)) bad[c]=1
        if ($21 == "" || $21 == "none") bad[c]=1
        if (!(c in fp)) fp[c]=$21; else if (fp[c] != $21) bad[c]=1
        resident[c,m]+=$18+0; rss[c,m]+=$11+0
      }
      END {
        for (i=1; i<=n; i++) {
          c=order[i]; pairs=0; sl=0; sc=0; sd=0; sd2=0; wins=0
          for (r=1; r<=expected; r++) {
            key=c SUBSEP r
            if (ops[key,"local"] > 0 && ops[key,"cxl"] > 0) {d=100*(ops[key,"cxl"]/ops[key,"local"]-1); pairs++; sl+=ops[key,"local"]; sc+=ops[key,"cxl"]; sd+=d; sd2+=d*d; if (d>0) wins++}
          }
          safe=(pairs == expected && !bad[c]); reason=(safe ? "ok" : (pairs != expected ? "incomplete" : "unsafe-row"))
          md=(pairs?sd/pairs:0); variance=(pairs>1?(sd2-sd*sd/pairs)/(pairs-1):0); if (variance<0) variance=0
          print c,workload,safe,reason,pairs,(pairs?sl/pairs:0),(pairs?sc/pairs:0),md,sqrt(variance),wins,fp[c],(rows[c,"cxl"]?resident[c,"cxl"]/rows[c,"cxl"]:0),(rows[c,"local"]?rss[c,"local"]/rows[c,"local"]:0),(rows[c,"cxl"]?rss[c,"cxl"]/rows[c,"cxl"]:0)
        }
      }
      ' "${RESULT_DIR}/finalists.txt" "${OBSERVATIONS}" >>"${RESULT_DIR}/final-summary.csv"
    done
  fi
  awk -F, -v OFS=, '
    NR > 1 && $1 == "final-native" {
      w=$3; n[w]++; sum[w]+=$9; sumsq[w]+=$9*$9; if ($8 != "ok") bad[w]=1
    }
    END {
      print "workload,rows,safe,mean_ops,stddev_ops"
      for (i=1; i<=2; i++) {w=(i==1?"a":"b"); mean=(n[w]?sum[w]/n[w]:0); var=(n[w]>1?(sumsq[w]-sum[w]*sum[w]/n[w])/(n[w]-1):0); if(var<0)var=0; print w,n[w]+0,(!bad[w]&&n[w]>0),mean,sqrt(var)}
    }
  ' "${OBSERVATIONS}" >"${RESULT_DIR}/native-summary.csv"
}

finalize() {
  local status="$1"
  if [[ ! -e "${RESULT_DIR}/finalists.txt" ]]; then : >"${RESULT_DIR}/finalists.txt"; fi
  write_final_summary
  rows_recorded="$(awk 'END {print (NR > 0 ? NR - 1 : 0)}' "${OBSERVATIONS}")"
  printf 'finished_at=%s\nfinal_status=%s\nrows_recorded=%s\n' "$(date --iso-8601=seconds)" "${status}" "${rows_recorded}" >>"${MANIFEST}"
  {
    echo '# XIndex YCSB-B Adaptive Sweep'
    echo
    echo "- Status: ${status}"
    echo "- Built parameter configs: ${CONFIG_COUNT}"
    echo "- Static-unique benchmark configs: ${SELECTED_COUNT}"
    echo "- Rows recorded: ${rows_recorded}"
    echo '- Execution: one full 400M-operation trace per row'
    echo '- Screen/confirmation workload: YCSB-B'
    echo "- Finalists: $(paste -sd, "${RESULT_DIR}/finalists.txt" 2>/dev/null || true)"
    echo
    echo '## Final local/CXL results'
    echo
    echo '| Candidate | Workload | Pairs | Local M op/s | CXL M op/s | Paired delta | Stddev | Wins | CXL resident GiB |'
    echo '|---|---|---:|---:|---:|---:|---:|---:|---:|'
    awk -F, 'NR > 1 {printf "| %s | %s | %d | %.3f | %.3f | %+.2f%% | %.2f%%p | %d | %.3f |\n",$1,toupper($2),$5,$6/1e6,$7/1e6,$8,$9,$10,$12/(1024^3)}' "${RESULT_DIR}/final-summary.csv"
  } >"${RESULT_DIR}/summary.md"
  echo "[complete] status=${status} result=${RESULT_DIR}"
}

on_signal() {
  echo "[signal] interrupted; preserving partial results"
  finalize interrupted
  exit 130
}
trap on_signal INT TERM

echo "[phase] B screen: ${#SELECTED_IDS[@]} static-unique config(s)"
for candidate in "${SELECTED_IDS[@]}"; do
  if ! run_pair screen "${candidate}" b 1; then break; fi
done
write_screen_summary
write_screen_ranking

mapfile -t CONFIRM_IDS <"${RESULT_DIR}/promoted-confirm.txt"
echo "[phase] B confirmation: ${#CONFIRM_IDS[@]} candidate(s)"
if [[ "${TIME_EXHAUSTED}" -eq 0 ]]; then
  for candidate in "${CONFIRM_IDS[@]}"; do
    for replicate in $(seq 2 $((CONFIRM_EXTRA_PAIRS + 1))); do
      if ! run_pair confirm "${candidate}" b "${replicate}"; then break 2; fi
    done
  done
fi
write_confirm_summary
write_confirm_ranking

mapfile -t FINAL_IDS <"${RESULT_DIR}/finalists.txt"
echo "[phase] A/B final: ${#FINAL_IDS[@]} candidate(s)"
if [[ "${TIME_EXHAUSTED}" -eq 0 ]]; then
  for replicate in $(seq 1 "${FINAL_ROUNDS}"); do
    if [[ $((replicate % 2)) -eq 1 ]]; then workloads="a b"; else workloads="b a"; fi
    for workload in ${workloads}; do
      if ! can_start_block 1; then break 2; fi
      run_row final-native native "${workload}" "${replicate}" native
      for candidate in "${FINAL_IDS[@]}"; do
        if ! run_pair final "${candidate}" "${workload}" "${replicate}"; then break 3; fi
      done
    done
  done
fi

if [[ "${TIME_EXHAUSTED}" -eq 1 ]]; then finalize budget-partial; else finalize complete; fi
