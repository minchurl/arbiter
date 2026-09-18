#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=check

# Search shape.  Candidate generation is deterministic; changing the seed makes
# a different, but still reproducible, sweep.
RAW_CANDIDATES="${HOTSET_RAW_CANDIDATES:-100}"
MAX_UNIQUE_CANDIDATES="${HOTSET_MAX_UNIQUE_CANDIDATES:-50}"
SEARCH_SEED="${HOTSET_SEARCH_SEED:-20260820}"
TOP_CONFIRM="${HOTSET_TOP_CONFIRM:-16}"
TOP_FINAL="${HOTSET_TOP_FINAL:-5}"
CONFIRM_EXTRA_PAIRS="${HOTSET_CONFIRM_EXTRA_PAIRS:-2}"
FINAL_EXTRA_PAIRS="${HOTSET_FINAL_EXTRA_PAIRS:-4}"

# Promotion intentionally keeps a broad band.  Only clearly poor candidates
# are removed after the short screen; confirmation keeps two policies with the
# same runtime site set so one noisy 15-second pair does not decide the sweep.
SCREEN_MIN_DELTA_PCT="${HOTSET_SCREEN_MIN_DELTA_PCT:--15}"
CONFIRM_MIN_DELTA_PCT="${HOTSET_CONFIRM_MIN_DELTA_PCT:--10}"
MAX_CONFIRM_PER_RUNTIME_FINGERPRINT="${HOTSET_MAX_CONFIRM_PER_RUNTIME_FINGERPRINT:-2}"
MAX_FINAL_PER_RUNTIME_FINGERPRINT="${HOTSET_MAX_FINAL_PER_RUNTIME_FINGERPRINT:-1}"

# Measured intervals.  Every row is a fresh process and therefore includes a
# fresh index construction before the measured transaction interval.
SCREEN_DURATION="${HOTSET_SCREEN_DURATION_SECONDS:-15}"
SCREEN_SAMPLE="${HOTSET_SCREEN_SAMPLE_SECONDS:-5}"
CONFIRM_DURATION="${HOTSET_CONFIRM_DURATION_SECONDS:-60}"
CONFIRM_SAMPLE="${HOTSET_CONFIRM_SAMPLE_SECONDS:-10}"
FINAL_DURATION="${HOTSET_FINAL_DURATION_SECONDS:-180}"
FINAL_SAMPLE="${HOTSET_FINAL_SAMPLE_SECONDS:-30}"
NATIVE_DURATION="${HOTSET_NATIVE_DURATION_SECONDS:-60}"
NATIVE_SAMPLE="${HOTSET_NATIVE_SAMPLE_SECONDS:-10}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-2}"

# The setup estimate controls admission of a new pair near the deadline.  A
# separate per-row timeout protects against an unexpectedly stuck trace load.
SETUP_BUDGET_SECONDS="${XINDEX_SETUP_BUDGET_SECONDS:-65}"
ROW_TIMEOUT_OVERHEAD_SECONDS="${XINDEX_ROW_TIMEOUT_OVERHEAD_SECONDS:-240}"
BUILD_BUDGET_SECONDS="${HOTSET_BUILD_BUDGET_SECONDS:-300}"
FINALIZE_RESERVE_SECONDS="${HOTSET_FINALIZE_RESERVE_SECONDS:-300}"
MAX_WALL_SECONDS="${OVERNIGHT_MAX_WALL_SECONDS:-28800}"
END_DEADLINE="${OVERNIGHT_END_DEADLINE:-}"

LOAD_RECORDS=100000000
TX_OPS=400000000
XINDEX_FG="${XINDEX_FG:-31}"
XINDEX_BG="${XINDEX_BG:-1}"
CPU_NODE="${ARBITER_CPU_NODE:-0}"
MEM_NODE="${ARBITER_MEM_NODE:-0}"
TARGET_NODE="${ARBITER_TARGET_NODE:-2}"
MEMORY_MAX="${MEMORY_MAX:-64G}"
MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-0}"
ARENA_SLAB_BYTES="${ARBITER_ARENA_SLAB_BYTES:-2097152}"
ARENA_RESERVE_BYTES="${ARBITER_ARENA_RESERVE_BYTES:-25769803776}"
ARENA_SLOT_ALIGNMENT="${ARBITER_ARENA_SLOT_ALIGNMENT:-64}"

DATA_DIR="${XINDEX_SCALE_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"
LOAD_TRACE="${DATA_DIR}/xindex_load_ycsb_a.dat"
TX_TRACE="${DATA_DIR}/xindex_transaction_ycsb_a.dat"
EXPECTED_LOAD_BYTES=5388149510
EXPECTED_TX_BYTES=21757793131

ARBITER_BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"
LLVM_PREFIX="${LLVM_PREFIX:-${ROOT_DIR}/.tools/llvm-18.1.8}"
CLANGXX="${CLANGXX:-${LLVM_PREFIX}/bin/clang++}"
OPT="${OPT:-${ROOT_DIR}/.tools/llvm18-apt-root/usr/bin/opt-18}"
LLVM_SHARED_LIB_DIR="${LLVM_SHARED_LIB_DIR:-${ROOT_DIR}/.tools/libllvm18-root/usr/lib/x86_64-linux-gnu}"
LLVM_TINFO_LIB_DIR="${LLVM_TINFO_LIB_DIR:-${ROOT_DIR}/.tools/libtinfo5-root/lib/x86_64-linux-gnu}"
CLANG_STDCXX_LIB_DIR="${CLANG_STDCXX_LIB_DIR:-${ROOT_DIR}/.tools/libstdcxx}"
CLANG_CXX_INCLUDE_ROOT="${CLANG_CXX_INCLUDE_ROOT:-/usr/include/c++/11}"
CLANG_CXX_TARGET_INCLUDE="${CLANG_CXX_TARGET_INCLUDE:-/usr/include/x86_64-linux-gnu/c++/11}"
LLVM_TOOL_LD_LIBRARY_PATH="${LLVM_SHARED_LIB_DIR}:${LLVM_TINFO_LIB_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
LLVM_TOOL_LIBRARY_PATH="${CLANG_STDCXX_LIB_DIR}${LIBRARY_PATH:+:${LIBRARY_PATH}}"
LLVM_TOOL_CPLUS_INCLUDE_PATH="${CLANG_CXX_INCLUDE_ROOT}:${CLANG_CXX_TARGET_INCLUDE}:${CLANG_CXX_INCLUDE_ROOT}/backward${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"
MKL_INCLUDE_DIR="${MKL_INCLUDE_DIR:-/opt/intel/oneapi/mkl/latest/include}"
MKL_LINK_DIR="${MKL_LINK_DIR:-/opt/intel/oneapi/mkl/latest/lib}"
MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR:-/opt/intel/oneapi/mkl/latest/lib}"
PLUGIN="${ARBITER_LLVM_PLUGIN:-${ARBITER_BUILD_DIR}/lib/ArbiterLLVMPlugin.so}"
RUNTIME_LIB="${ARBITER_RUNTIME_LIB:-${ARBITER_BUILD_DIR}/runtime/libarbiter_runtime.a}"

# A retained build supplies the common native binary and the three native
# drift anchors.  Rewritten binaries are rebuilt for every generated config.
NATIVE_BUILD_DIR="${ROOT_DIR}/build/arbiter-bench/xindex-hotset-auto-k3-s12"
NATIVE_CONFIG="${NATIVE_BUILD_DIR}/hotset-build.config"
NATIVE_BINARY="${NATIVE_BUILD_DIR}/ycsb_bench-native"

RUN_ID="${HOTSET_RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/hotset-broad-sweep-v2-${RUN_ID}}"

usage() {
  cat <<EOF
usage: $0 --check | --run

Builds and evaluates a deterministic broad set of automatic hot-set policies
against the full XIndex/YCSB A trace.  It does not pin a source site ID.

Default adaptive schedule:
  generate/build:           100 fixed-size-only raw configurations
  static de-duplication:    selected-site fingerprint, at most 50 candidates
  screen:                   one 15s local/CXL pair per candidate
  screen filter:            discard only unsafe or below -15%; keep 2/runtime set
  confirmation:             up to 16, two additional 60s pairs (3 total)
  confirmation filter:      discard only unsafe or below -10%; keep 1/runtime set
  final:                    up to 5, four additional 180s pairs (7 total)
  native drift anchors:     start, middle, end; 60s each
  throughput samples:       5s / 10s / 30s by phase
  foreground/background:   31 / 1 on CPU node 0
  local/CXL nodes:          0 / 2
  MemoryMax/swap:           64G / 0
  strict arena reserve:     24 GiB virtual, MAP_NORESERVE-backed
  hard controller budget:  8 hours

The controller rejects dynamic-size allocation sites because the current arena
uses one fixed slot size per site.  It then uses runtime allocation-site IDs to
retain diversity during promotion.  A row with no arena report is recorded but
cannot be promoted.

Useful overrides:
  OVERNIGHT_END_DEADLINE       optional GNU date string, e.g. 'tomorrow 09:00'
  HOTSET_SEARCH_SEED           deterministic search seed
  HOTSET_RAW_CANDIDATES        default 100
  HOTSET_MAX_UNIQUE_CANDIDATES default 50
  HOTSET_SCREEN_MIN_DELTA_PCT  default -15
  HOTSET_CONFIRM_MIN_DELTA_PCT default -10
  RESULT_DIR / HOTSET_RUN_ID   result naming

--check validates the machine, tools, traces, retained native binary, cgroup,
and schedule.  It does not create a result directory, compile, or benchmark.
The run never drops page cache and never changes other processes' affinity.
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

require_number() {
  local name="$1" value="$2"
  if [[ ! "${value}" =~ ^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
    echo "${name} must be a number: ${value}" >&2
    exit 1
  fi
}

for value in \
  "RAW_CANDIDATES:${RAW_CANDIDATES}" \
  "MAX_UNIQUE_CANDIDATES:${MAX_UNIQUE_CANDIDATES}" \
  "SEARCH_SEED:${SEARCH_SEED}" \
  "TOP_CONFIRM:${TOP_CONFIRM}" \
  "TOP_FINAL:${TOP_FINAL}" \
  "MAX_CONFIRM_PER_RUNTIME_FINGERPRINT:${MAX_CONFIRM_PER_RUNTIME_FINGERPRINT}" \
  "MAX_FINAL_PER_RUNTIME_FINGERPRINT:${MAX_FINAL_PER_RUNTIME_FINGERPRINT}" \
  "CONFIRM_EXTRA_PAIRS:${CONFIRM_EXTRA_PAIRS}" \
  "FINAL_EXTRA_PAIRS:${FINAL_EXTRA_PAIRS}" \
  "SCREEN_DURATION:${SCREEN_DURATION}" \
  "SCREEN_SAMPLE:${SCREEN_SAMPLE}" \
  "CONFIRM_DURATION:${CONFIRM_DURATION}" \
  "CONFIRM_SAMPLE:${CONFIRM_SAMPLE}" \
  "FINAL_DURATION:${FINAL_DURATION}" \
  "FINAL_SAMPLE:${FINAL_SAMPLE}" \
  "NATIVE_DURATION:${NATIVE_DURATION}" \
  "NATIVE_SAMPLE:${NATIVE_SAMPLE}" \
  "SETUP_BUDGET_SECONDS:${SETUP_BUDGET_SECONDS}" \
  "ROW_TIMEOUT_OVERHEAD_SECONDS:${ROW_TIMEOUT_OVERHEAD_SECONDS}" \
  "BUILD_BUDGET_SECONDS:${BUILD_BUDGET_SECONDS}" \
  "FINALIZE_RESERVE_SECONDS:${FINALIZE_RESERVE_SECONDS}" \
  "MAX_WALL_SECONDS:${MAX_WALL_SECONDS}" \
  "XINDEX_FG:${XINDEX_FG}" \
  "XINDEX_BG:${XINDEX_BG}" \
  "ARENA_SLAB_BYTES:${ARENA_SLAB_BYTES}" \
  "ARENA_RESERVE_BYTES:${ARENA_RESERVE_BYTES}" \
  "ARENA_SLOT_ALIGNMENT:${ARENA_SLOT_ALIGNMENT}"; do
  require_positive_integer "${value%%:*}" "${value#*:}"
done
require_nonnegative_integer COOLDOWN_SECONDS "${COOLDOWN_SECONDS}"
require_number SCREEN_MIN_DELTA_PCT "${SCREEN_MIN_DELTA_PCT}"
require_number CONFIRM_MIN_DELTA_PCT "${CONFIRM_MIN_DELTA_PCT}"

if [[ "${RAW_CANDIDATES}" -lt 14 ]]; then
  echo "HOTSET_RAW_CANDIDATES must be at least 14 so all designed anchors are included" >&2
  exit 1
fi
if [[ "${MAX_UNIQUE_CANDIDATES}" -gt "${RAW_CANDIDATES}" ]]; then
  echo "HOTSET_MAX_UNIQUE_CANDIDATES cannot exceed HOTSET_RAW_CANDIDATES" >&2
  exit 1
fi
if [[ "${TOP_FINAL}" -gt "${TOP_CONFIRM}" ]]; then
  echo "HOTSET_TOP_FINAL cannot exceed HOTSET_TOP_CONFIRM" >&2
  exit 1
fi
if [[ "${TOP_CONFIRM}" -gt "${MAX_UNIQUE_CANDIDATES}" ]]; then
  echo "HOTSET_TOP_CONFIRM cannot exceed HOTSET_MAX_UNIQUE_CANDIDATES" >&2
  exit 1
fi
for pair in \
  "screen:${SCREEN_SAMPLE}:${SCREEN_DURATION}" \
  "confirm:${CONFIRM_SAMPLE}:${CONFIRM_DURATION}" \
  "final:${FINAL_SAMPLE}:${FINAL_DURATION}" \
  "native:${NATIVE_SAMPLE}:${NATIVE_DURATION}"; do
  IFS=: read -r phase sample duration <<<"${pair}"
  if [[ "${sample}" -ge "${duration}" ]]; then
    echo "${phase} sample interval must be shorter than its duration" >&2
    exit 1
  fi
done
if [[ "${MEMORY_MAX}" != "64G" ]]; then
  echo "this reviewed sweep requires MEMORY_MAX=64G; got ${MEMORY_MAX}" >&2
  exit 1
fi
if [[ "${MEMORY_SWAP_MAX}" != "0" ]]; then
  echo "this reviewed sweep requires MEMORY_SWAP_MAX=0; got ${MEMORY_SWAP_MAX}" >&2
  exit 1
fi
if [[ "${ARENA_RESERVE_BYTES}" -gt 34359738368 ]]; then
  echo "arena reserve exceeds the reviewed 32 GiB safety ceiling" >&2
  exit 1
fi
if [[ "${XINDEX_FG}" -lt 24 ]]; then
  echo "XINDEX_FG=${XINDEX_FG} is below the observed 24-core coherence threshold" >&2
  exit 1
fi

for command in awk cat cmp cp cut date git grep ldd lscpu mkdir numactl paste pgrep \
  realpath sed sha256sum sleep sort stat systemd-run tee timeout; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "missing required command: ${command}" >&2
    exit 1
  fi
done

# The previous controller used an unparenthesized ternary after print.  Some
# awk implementations parse that form as a redirection and fail only after a
# benchmark row has finished.  Exercise the exact row-count expression now.
if ! AWK_COUNT_SELF_TEST="$(printf 'header\nrow\n' | awk 'END {print (NR > 0 ? NR - 1 : 0)}')"; then
  echo "awk cannot execute the controller row-count expression" >&2
  exit 1
fi
if [[ "${AWK_COUNT_SELF_TEST}" != 1 ]]; then
  echo "awk row-count self-test returned ${AWK_COUNT_SELF_TEST}; expected 1" >&2
  exit 1
fi

for tool in "${CLANGXX}" "${OPT}"; do
  if [[ ! -x "${tool}" ]]; then
    echo "missing executable LLVM tool: ${tool}" >&2
    exit 1
  fi
done
for lib_dir in "${LLVM_SHARED_LIB_DIR}" "${LLVM_TINFO_LIB_DIR}" "${CLANG_STDCXX_LIB_DIR}"; do
  if [[ ! -d "${lib_dir}" ]]; then
    echo "missing LLVM compatibility library directory: ${lib_dir}" >&2
    exit 1
  fi
done
for include_dir in "${CLANG_CXX_INCLUDE_ROOT}" "${CLANG_CXX_TARGET_INCLUDE}"; do
  if [[ ! -d "${include_dir}" ]]; then
    echo "missing C++ standard-library include directory: ${include_dir}" >&2
    exit 1
  fi
done
OPT_MAJOR="$(env LD_LIBRARY_PATH="${LLVM_TOOL_LD_LIBRARY_PATH}" "${OPT}" --version | awk '/LLVM version/ {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) {split($i,v,"."); print v[1]; exit}}')"
CLANG_MAJOR="$(env LD_LIBRARY_PATH="${LLVM_TOOL_LD_LIBRARY_PATH}" "${CLANGXX}" --version | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\./) {split($i,v,"."); print v[1]; exit}}')"
if [[ "${OPT_MAJOR}" != "18" || "${CLANG_MAJOR}" != "18" ]]; then
  echo "the retained Arbiter plugin requires LLVM 18; clang=${CLANG_MAJOR:-unknown}, opt=${OPT_MAJOR:-unknown}" >&2
  exit 1
fi

for path in \
  "${ROOT_DIR}/scripts/build-xindex-llvm.sh" \
  "${ROOT_DIR}/scripts/run-protected-hotset-experiment.sh" \
  "${ROOT_DIR}/scripts/xindex-experiments/hotset.sh" \
  "${PLUGIN}" "${RUNTIME_LIB}" \
  "${NATIVE_CONFIG}" \
  "${NATIVE_BUILD_DIR}/ycsb_bench.bc" \
  "${NATIVE_BUILD_DIR}/ycsb_bench.hotset-sites.csv" \
  "${NATIVE_BUILD_DIR}/ycsb_bench.hotset-effective.opt-args"; do
  if [[ ! -s "${path}" ]]; then
    echo "missing required artifact: ${path}" >&2
    exit 1
  fi
done
if [[ ! -x "${NATIVE_BINARY}" ]]; then
  echo "missing retained native XIndex binary: ${NATIVE_BINARY}" >&2
  exit 1
fi
if ldd "${NATIVE_BINARY}" | grep -q 'not found'; then
  echo "retained native binary has unresolved shared libraries" >&2
  ldd "${NATIVE_BINARY}" >&2
  exit 1
fi
if env LD_LIBRARY_PATH="${LLVM_TOOL_LD_LIBRARY_PATH}" ldd "${PLUGIN}" | grep -q 'not found'; then
  echo "Arbiter LLVM plugin has unresolved shared libraries" >&2
  env LD_LIBRARY_PATH="${LLVM_TOOL_LD_LIBRARY_PATH}" ldd "${PLUGIN}" >&2
  exit 1
fi
if ! printf '#include <algorithm>\nint main() { return 0; }\n' | \
    env LD_LIBRARY_PATH="${LLVM_TOOL_LD_LIBRARY_PATH}" LIBRARY_PATH="${LLVM_TOOL_LIBRARY_PATH}" CPLUS_INCLUDE_PATH="${LLVM_TOOL_CPLUS_INCLUDE_PATH}" \
    "${CLANGXX}" -x c++ - -o /dev/null >/dev/null 2>&1; then
  echo "LLVM 18 clang++ cannot compile and link a minimal C++ program" >&2
  exit 1
fi
if ! env LD_LIBRARY_PATH="${LLVM_TOOL_LD_LIBRARY_PATH}" \
    "${OPT}" -load-pass-plugin "${PLUGIN}" -passes=arbiter-report-sites \
    -arbiter-report-path=/dev/null -disable-output \
    "${NATIVE_BUILD_DIR}/ycsb_bench.bc" >/dev/null 2>&1; then
  echo "LLVM 18 opt cannot load the retained Arbiter plugin" >&2
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
if [[ $((XINDEX_FG + XINDEX_BG)) -gt "${NODE_CPU_COUNT}" ]]; then
  echo "foreground + background workers exceed node ${CPU_NODE} CPU count (${NODE_CPU_COUNT})" >&2
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

for trace in "${LOAD_TRACE}" "${TX_TRACE}"; do
  if [[ ! -s "${trace}" ]]; then
    echo "missing full trace: ${trace}" >&2
    exit 1
  fi
done
LOAD_BYTES="$(stat -c %s "${LOAD_TRACE}")"
TX_BYTES="$(stat -c %s "${TX_TRACE}")"
if [[ "${LOAD_BYTES}" != "${EXPECTED_LOAD_BYTES}" || "${TX_BYTES}" != "${EXPECTED_TX_BYTES}" ]]; then
  echo "full trace size mismatch: load=${LOAD_BYTES}, tx=${TX_BYTES}" >&2
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
if ! systemd-run --user --scope -p MemoryMax=64G -p MemorySwapMax=0 true >/dev/null 2>&1; then
  echo "failed to create a user scope with MemoryMax=64G and MemorySwapMax=0" >&2
  exit 1
fi

SCREEN_ROWS=$((MAX_UNIQUE_CANDIDATES * 2))
CONFIRM_ROWS=$((TOP_CONFIRM * CONFIRM_EXTRA_PAIRS * 2))
FINAL_ROWS=$((TOP_FINAL * FINAL_EXTRA_PAIRS * 2))
NATIVE_ROWS=3
ESTIMATED_SECONDS=$((
  SCREEN_ROWS * (SETUP_BUDGET_SECONDS + SCREEN_DURATION + COOLDOWN_SECONDS) +
  CONFIRM_ROWS * (SETUP_BUDGET_SECONDS + CONFIRM_DURATION + COOLDOWN_SECONDS) +
  FINAL_ROWS * (SETUP_BUDGET_SECONDS + FINAL_DURATION + COOLDOWN_SECONDS) +
  NATIVE_ROWS * (SETUP_BUDGET_SECONDS + NATIVE_DURATION + COOLDOWN_SECONDS) +
  BUILD_BUDGET_SECONDS
))
NOW_EPOCH="$(date +%s)"
ESTIMATED_END_EPOCH=$((NOW_EPOCH + ESTIMATED_SECONDS))
DEADLINE_EPOCH=""
if [[ -n "${END_DEADLINE}" ]]; then
  if ! DEADLINE_EPOCH="$(date -d "${END_DEADLINE}" +%s 2>/dev/null)"; then
    echo "cannot parse OVERNIGHT_END_DEADLINE=${END_DEADLINE}" >&2
    exit 1
  fi
  if [[ "${DEADLINE_EPOCH}" -le "${NOW_EPOCH}" ]]; then
    echo "OVERNIGHT_END_DEADLINE is not in the future: ${END_DEADLINE}" >&2
    exit 1
  fi
fi

cat <<EOF
Broad hot-set sweep preflight passed.
  mode:                      ${MODE}
  raw / max static-unique:   ${RAW_CANDIDATES} / ${MAX_UNIQUE_CANDIDATES}
  screen / confirm / final:  ${SCREEN_DURATION}s / ${CONFIRM_DURATION}s / ${FINAL_DURATION}s
  promoted candidates:       ${TOP_CONFIRM}, then ${TOP_FINAL}
  promotion floors:          ${SCREEN_MIN_DELTA_PCT}% / ${CONFIRM_MIN_DELTA_PCT}%
  per-runtime-set caps:       ${MAX_CONFIRM_PER_RUNTIME_FINGERPRINT} / ${MAX_FINAL_PER_RUNTIME_FINGERPRINT}
  maximum fresh-process rows:$((SCREEN_ROWS + CONFIRM_ROWS + FINAL_ROWS + NATIVE_ROWS))
  estimated wall time:       $(awk -v s="${ESTIMATED_SECONDS}" 'BEGIN {printf "%.2f hours", s / 3600}')
  estimated finish:          $(date -d "@${ESTIMATED_END_EPOCH}" '+%F %T %Z')
  controller hard budget:    $(awk -v s="${MAX_WALL_SECONDS}" 'BEGIN {printf "%.2f hours", s / 3600}')
  explicit end deadline:     ${END_DEADLINE:-none}
  full trace:                ${LOAD_RECORDS} / ${TX_OPS}
  CPU / local / CXL node:    ${CPU_NODE} / ${MEM_NODE} / ${TARGET_NODE}
  foreground / background:   ${XINDEX_FG} / ${XINDEX_BG}
  hard memory / swap cap:    ${MEMORY_MAX} / ${MEMORY_SWAP_MAX}
  arena virtual reserve:     ${ARENA_RESERVE_BYTES} bytes
  LLVM tools:                ${CLANGXX}, ${OPT}
  result:                    ${RESULT_DIR}
EOF
if [[ -n "${DEADLINE_EPOCH}" && "${ESTIMATED_END_EPOCH}" -gt "${DEADLINE_EPOCH}" ]]; then
  echo "  note: estimate reaches the explicit deadline; the controller will stop before starting an unsafe final pair"
fi
if [[ "${MODE}" == check ]]; then
  echo "check-only mode: no directory, build, cache reset, or benchmark was started"
  exit 0
fi

mkdir -p "${RESULT_DIR}/configs" "${RESULT_DIR}/builds" "${RESULT_DIR}/build-logs"
CONSOLE_LOG="${RESULT_DIR}/overnight-console.log"
exec > >(tee -a "${CONSOLE_LOG}") 2>&1

START_EPOCH="$(date +%s)"
STOP_EPOCH=$((START_EPOCH + MAX_WALL_SECONDS))
if [[ -n "${DEADLINE_EPOCH}" && "${DEADLINE_EPOCH}" -lt "${STOP_EPOCH}" ]]; then
  STOP_EPOCH="${DEADLINE_EPOCH}"
fi

MANIFEST="${RESULT_DIR}/manifest.txt"
OBSERVATIONS="${RESULT_DIR}/observations.csv"
ALL_SAMPLES="${RESULT_DIR}/throughput-samples.csv"
CANDIDATES_CSV="${RESULT_DIR}/candidates.csv"
SELECTED_CSV="${RESULT_DIR}/selected-candidates.csv"
SELECTED_LIST="${RESULT_DIR}/selected-candidates.txt"

cat >"${MANIFEST}" <<EOF
schema_version=2
started_at=$(date '+%F %T %Z')
controller=$(realpath "$0")
git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || printf unknown)
search_seed=${SEARCH_SEED}
raw_candidates=${RAW_CANDIDATES}
max_unique_candidates=${MAX_UNIQUE_CANDIDATES}
top_confirm=${TOP_CONFIRM}
top_final=${TOP_FINAL}
screen_min_delta_pct=${SCREEN_MIN_DELTA_PCT}
confirm_min_delta_pct=${CONFIRM_MIN_DELTA_PCT}
max_confirm_per_runtime_fingerprint=${MAX_CONFIRM_PER_RUNTIME_FINGERPRINT}
max_final_per_runtime_fingerprint=${MAX_FINAL_PER_RUNTIME_FINGERPRINT}
dynamic_size_policy=excluded
confirm_extra_pairs=${CONFIRM_EXTRA_PAIRS}
final_extra_pairs=${FINAL_EXTRA_PAIRS}
screen_duration_seconds=${SCREEN_DURATION}
screen_sample_seconds=${SCREEN_SAMPLE}
confirm_duration_seconds=${CONFIRM_DURATION}
confirm_sample_seconds=${CONFIRM_SAMPLE}
final_duration_seconds=${FINAL_DURATION}
final_sample_seconds=${FINAL_SAMPLE}
native_duration_seconds=${NATIVE_DURATION}
native_sample_seconds=${NATIVE_SAMPLE}
setup_budget_seconds=${SETUP_BUDGET_SECONDS}
row_timeout_overhead_seconds=${ROW_TIMEOUT_OVERHEAD_SECONDS}
max_wall_seconds=${MAX_WALL_SECONDS}
stop_epoch=${STOP_EPOCH}
stop_time=$(date -d "@${STOP_EPOCH}" '+%F %T %Z')
load_records=${LOAD_RECORDS}
transaction_ops=${TX_OPS}
load_trace=${LOAD_TRACE}
load_trace_bytes=${LOAD_BYTES}
transaction_trace=${TX_TRACE}
transaction_trace_bytes=${TX_BYTES}
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
clangxx=${CLANGXX}
opt=${OPT}
plugin=${PLUGIN}
runtime_lib=${RUNTIME_LIB}
llvm_tool_ld_library_path=${LLVM_TOOL_LD_LIBRARY_PATH}
llvm_tool_library_path=${LLVM_TOOL_LIBRARY_PATH}
llvm_tool_cplus_include_path=${LLVM_TOOL_CPLUS_INCLUDE_PATH}
native_binary=${NATIVE_BINARY}
EOF
git -C "${ROOT_DIR}" status --short >"${RESULT_DIR}/git-status-at-start.txt" || true
cp "$0" "${RESULT_DIR}/controller.sh"
if [[ -f "${ROOT_DIR}/docs/experiments/hotset-broad-sweep-plan.md" ]]; then
  cp "${ROOT_DIR}/docs/experiments/hotset-broad-sweep-plan.md" "${RESULT_DIR}/plan.md"
fi
sha256sum "$0" "${NATIVE_BINARY}" "${PLUGIN}" "${RUNTIME_LIB}" >"${RESULT_DIR}/artifacts.sha256"

printf 'phase,candidate,replicate,position,requested_mode,actual_mode,status,throughput,max_rss_kb,swaps,arena_allocations,arena_peak_live,arena_assigned_bytes,arena_fallbacks,arena_resident_bytes,arena_majority_node,arena_query_error_pages,runtime_fingerprint,static_fingerprint,time_sec,wall_time,driver_exit,duration_seconds,sample_seconds,result_dir\n' >"${OBSERVATIONS}"
printf 'phase,candidate,replicate,position,requested_mode,benchmark,workload,config,repeat,actual_mode,elapsed_sec,interval_sec,interval_ops,interval_ops_per_sec,cumulative_ops,cumulative_ops_per_sec,final,log\n' >"${ALL_SAMPLES}"
printf 'raw_id,design,status,static_fingerprint,selected_site_count,config_path,build_dir,build_log\n' >"${CANDIDATES_CSV}"
printf 'candidate,raw_id,design,static_fingerprint,selected_site_count,config_path,build_dir\n' >"${SELECTED_CSV}"
: >"${SELECTED_LIST}"

RNG_STATE=$((SEARCH_SEED & 2147483647))
RNG_VALUE=0
PICKED=""
rand_below() {
  local bound="$1"
  RNG_STATE=$(((1103515245 * RNG_STATE + 12345) & 2147483647))
  RNG_VALUE=$((RNG_STATE % bound))
}
pick_from() {
  local -n choices_ref="$1"
  rand_below "${#choices_ref[@]}"
  PICKED="${choices_ref[${RNG_VALUE}]}"
}

reset_policy() {
  MIN_SCORE=6
  SEED_LIMIT=3
  W_ESCAPE_RETURN=3
  W_ESCAPE_STORE=3
  W_ESCAPE_CALL=2
  W_SYNC_ATOMIC=3
  W_SYNC_STORE=2
  W_SYNC_INLINE_ASM=2
  W_SYNC_FILE=1
  W_WORKER_ENTRY=3
  W_WORKER_REACHABLE=2
  W_SIZE=1
  REQUIRE_ESCAPE=1
  REQUIRE_SYNC=1
  LARGE_THRESHOLD=4096
  INCLUDE_DYNAMIC=0
  EXPANSION=use
  MAX_SITES=16
  DYNAMIC_ESTIMATE=4096
  MAX_ESTIMATED_BYTES=0
  MAX_MEMBERS=4
  MIN_AFFINITY=3
  MAX_CALL_DEPTH=1
  MAX_LOAD_DEPTH=2
}

set_weight_bundle() {
  case "$1" in
    default) ;;
    escape-heavy)
      W_ESCAPE_RETURN=5; W_ESCAPE_STORE=6; W_ESCAPE_CALL=4
      W_SYNC_ATOMIC=2; W_SYNC_STORE=1; W_SYNC_INLINE_ASM=1
      W_WORKER_ENTRY=2; W_WORKER_REACHABLE=2; W_SIZE=1 ;;
    sync-heavy)
      W_ESCAPE_RETURN=2; W_ESCAPE_STORE=2; W_ESCAPE_CALL=1
      W_SYNC_ATOMIC=7; W_SYNC_STORE=5; W_SYNC_INLINE_ASM=4; W_SYNC_FILE=2
      W_WORKER_ENTRY=2; W_WORKER_REACHABLE=1; W_SIZE=1 ;;
    worker-heavy)
      W_ESCAPE_RETURN=2; W_ESCAPE_STORE=2; W_ESCAPE_CALL=2
      W_SYNC_ATOMIC=2; W_SYNC_STORE=2; W_SYNC_INLINE_ASM=1
      W_WORKER_ENTRY=7; W_WORKER_REACHABLE=6; W_SIZE=1 ;;
    size-heavy)
      W_ESCAPE_RETURN=2; W_ESCAPE_STORE=2; W_ESCAPE_CALL=1
      W_SYNC_ATOMIC=2; W_SYNC_STORE=1; W_SYNC_INLINE_ASM=1
      W_WORKER_ENTRY=2; W_WORKER_REACHABLE=1; W_SIZE=6 ;;
    flat)
      W_ESCAPE_RETURN=2; W_ESCAPE_STORE=2; W_ESCAPE_CALL=2
      W_SYNC_ATOMIC=2; W_SYNC_STORE=2; W_SYNC_INLINE_ASM=2; W_SYNC_FILE=2
      W_WORKER_ENTRY=2; W_WORKER_REACHABLE=2; W_SIZE=2 ;;
    hybrid)
      W_ESCAPE_RETURN=4; W_ESCAPE_STORE=5; W_ESCAPE_CALL=3
      W_SYNC_ATOMIC=5; W_SYNC_STORE=3; W_SYNC_INLINE_ASM=3; W_SYNC_FILE=1
      W_WORKER_ENTRY=4; W_WORKER_REACHABLE=4; W_SIZE=2 ;;
    *) echo "unknown weight bundle: $1" >&2; exit 1 ;;
  esac
}

RAW_INDEX=0
CURRENT_ID=""
next_candidate() {
  RAW_INDEX=$((RAW_INDEX + 1))
  CURRENT_ID="$(printf 'raw-%03d' "${RAW_INDEX}")"
  reset_policy
}

emit_candidate() {
  local design="$1"
  local config="${RESULT_DIR}/configs/${CURRENT_ID}.config"
  cat >"${config}" <<EOF
# Generated by run-hotset-broad-sweep-overnight.sh.
# search_seed=${SEARCH_SEED} raw_id=${CURRENT_ID} design=${design}
ARBITER_HITM_MIN_SCORE=${MIN_SCORE}
ARBITER_HITM_SEED_LIMIT=${SEED_LIMIT}
ARBITER_HITM_SEED_SITE_IDS=
ARBITER_HITM_WEIGHT_ESCAPE_RETURN=${W_ESCAPE_RETURN}
ARBITER_HITM_WEIGHT_ESCAPE_STORE=${W_ESCAPE_STORE}
ARBITER_HITM_WEIGHT_ESCAPE_CALL=${W_ESCAPE_CALL}
ARBITER_HITM_WEIGHT_SYNC_ATOMIC=${W_SYNC_ATOMIC}
ARBITER_HITM_WEIGHT_SYNC_STORE=${W_SYNC_STORE}
ARBITER_HITM_WEIGHT_SYNC_INLINE_ASM=${W_SYNC_INLINE_ASM}
ARBITER_HITM_WEIGHT_SYNC_FILE=${W_SYNC_FILE}
ARBITER_HITM_WEIGHT_WORKER_ENTRY=${W_WORKER_ENTRY}
ARBITER_HITM_WEIGHT_WORKER_REACHABLE=${W_WORKER_REACHABLE}
ARBITER_HITM_WEIGHT_SIZE=${W_SIZE}
ARBITER_HITM_REQUIRE_ESCAPE=${REQUIRE_ESCAPE}
ARBITER_HITM_REQUIRE_SYNC=${REQUIRE_SYNC}
ARBITER_HITM_LARGE_ALLOCATION_THRESHOLD=${LARGE_THRESHOLD}
ARBITER_HITM_INCLUDE_DYNAMIC_SIZE=${INCLUDE_DYNAMIC}
ARBITER_HOTSET_EXPANSION=${EXPANSION}
ARBITER_HOTSET_MAX_SITES=${MAX_SITES}
ARBITER_HOTSET_INCLUDE_MMAP=0
ARBITER_HOTSET_DYNAMIC_SIZE_ESTIMATE=${DYNAMIC_ESTIMATE}
ARBITER_HOTSET_MAX_ESTIMATED_BYTES=${MAX_ESTIMATED_BYTES}
ARBITER_HOTSET_MAX_MEMBERS_PER_SEED=${MAX_MEMBERS}
ARBITER_HOTSET_MEMBER_MIN_AFFINITY=${MIN_AFFINITY}
ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH=${MAX_CALL_DEPTH}
ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH=${MAX_LOAD_DEPTH}
EOF
  printf '%s\t%s\t%s\n' "${CURRENT_ID}" "${design}" "${config}" >>"${RESULT_DIR}/raw-candidates.tsv"
}

: >"${RESULT_DIR}/raw-candidates.tsv"

# Fourteen designed, pin-free reference points come first.  Their order deliberately
# makes the smallest static policy the representative when runtime behavior is
# identical (for example k3 and k6 both executing only site 68).
next_candidate; MIN_SCORE=13; SEED_LIMIT=1; INCLUDE_DYNAMIC=0; EXPANSION=none; MAX_SITES=1; MAX_MEMBERS=1; MAX_ESTIMATED_BYTES=1024; emit_candidate auto-k1-fixed
next_candidate; MIN_SCORE=13; SEED_LIMIT=2; INCLUDE_DYNAMIC=0; EXPANSION=none; MAX_SITES=2; MAX_MEMBERS=1; MAX_ESTIMATED_BYTES=1024; emit_candidate auto-k2-fixed
next_candidate; MIN_SCORE=12; SEED_LIMIT=3; INCLUDE_DYNAMIC=0; EXPANSION=none; MAX_SITES=3; MAX_MEMBERS=1; MAX_ESTIMATED_BYTES=1024; emit_candidate auto-k3-fixed
next_candidate; MIN_SCORE=12; SEED_LIMIT=6; INCLUDE_DYNAMIC=0; EXPANSION=none; MAX_SITES=6; MAX_MEMBERS=1; MAX_ESTIMATED_BYTES=1024; emit_candidate auto-k6-fixed
next_candidate; emit_candidate broad-default
next_candidate; SEED_LIMIT=8; MAX_SITES=24; MAX_MEMBERS=6; emit_candidate broad-top8
next_candidate; SEED_LIMIT=12; EXPANSION=none; MAX_SITES=12; MAX_MEMBERS=1; emit_candidate broad-top12-noexp
next_candidate; MIN_SCORE=4; SEED_LIMIT=16; REQUIRE_ESCAPE=0; REQUIRE_SYNC=0; MAX_SITES=32; MAX_MEMBERS=8; MIN_AFFINITY=1; MAX_CALL_DEPTH=2; MAX_LOAD_DEPTH=3; emit_candidate permissive-deep
next_candidate; MIN_SCORE=10; SEED_LIMIT=8; INCLUDE_DYNAMIC=0; EXPANSION=none; MAX_SITES=8; MAX_MEMBERS=1; emit_candidate strict-fixed
next_candidate; MIN_SCORE=6; SEED_LIMIT=6; LARGE_THRESHOLD=96; MAX_SITES=24; MIN_AFFINITY=1; emit_candidate fixed-small-threshold
next_candidate; SEED_LIMIT=8; MAX_SITES=24; MIN_AFFINITY=5; emit_candidate high-affinity
next_candidate; SEED_LIMIT=6; MAX_SITES=32; MAX_MEMBERS=8; MIN_AFFINITY=1; MAX_CALL_DEPTH=3; MAX_LOAD_DEPTH=4; emit_candidate deep-expansion
next_candidate; MIN_SCORE=8; SEED_LIMIT=8; set_weight_bundle flat; REQUIRE_ESCAPE=0; REQUIRE_SYNC=1; LARGE_THRESHOLD=64; EXPANSION=none; MAX_SITES=8; MAX_ESTIMATED_BYTES=1024; MAX_MEMBERS=1; MIN_AFFINITY=3; MAX_CALL_DEPTH=0; MAX_LOAD_DEPTH=0; emit_candidate flat-fixed-aggressive
next_candidate; MIN_SCORE=7; SEED_LIMIT=3; set_weight_bundle hybrid; REQUIRE_ESCAPE=1; REQUIRE_SYNC=1; LARGE_THRESHOLD=4096; EXPANSION=use; MAX_SITES=24; MAX_ESTIMATED_BYTES=1024; MAX_MEMBERS=2; MIN_AFFINITY=1; MAX_CALL_DEPTH=1; MAX_LOAD_DEPTH=4; emit_candidate hybrid-fixed-expansion

scores=(4 5 6 7 8 10 12 13 14)
seed_limits=(1 2 3 4 6 8 12 16 24)
gate_choices=(1:1 1:1 1:0 0:1 0:0)
large_thresholds=(64 96 128 512 4096 16384)
expansions=(none use use)
site_caps=(4 6 8 12 16 24 32)
byte_budgets=(0 0 16384 32768 65536)
member_caps=(1 2 4 6 8)
affinities=(1 3 5)
call_depths=(0 1 2 3)
load_depths=(0 1 2 3 4)
weight_bundles=(default escape-heavy sync-heavy worker-heavy size-heavy flat hybrid)

while [[ "${RAW_INDEX}" -lt "${RAW_CANDIDATES}" ]]; do
  next_candidate
  pick_from scores; MIN_SCORE="${PICKED}"
  pick_from seed_limits; SEED_LIMIT="${PICKED}"
  pick_from gate_choices; IFS=: read -r REQUIRE_ESCAPE REQUIRE_SYNC <<<"${PICKED}"
  pick_from large_thresholds; LARGE_THRESHOLD="${PICKED}"
  pick_from expansions; EXPANSION="${PICKED}"
  pick_from site_caps; MAX_SITES="${PICKED}"
  if [[ "${MAX_SITES}" -lt "${SEED_LIMIT}" ]]; then MAX_SITES="${SEED_LIMIT}"; fi
  if [[ "${MAX_SITES}" -gt 32 ]]; then MAX_SITES=32; fi
  pick_from byte_budgets; MAX_ESTIMATED_BYTES="${PICKED}"
  pick_from member_caps; MAX_MEMBERS="${PICKED}"
  pick_from affinities; MIN_AFFINITY="${PICKED}"
  pick_from call_depths; MAX_CALL_DEPTH="${PICKED}"
  pick_from load_depths; MAX_LOAD_DEPTH="${PICKED}"
  pick_from weight_bundles; bundle="${PICKED}"; set_weight_bundle "${bundle}"
  if [[ "${EXPANSION}" == none ]]; then
    MAX_SITES="${SEED_LIMIT}"
    MAX_MEMBERS=1
    MAX_CALL_DEPTH=0
    MAX_LOAD_DEPTH=0
  fi
  emit_candidate "random-${bundle}"
done

echo "[build] generated ${RAW_INDEX} deterministic raw configurations"
declare -A SEEN_STATIC=()
SELECTED_COUNT=0
BUILD_FAILURES=0
UNSAFE_DYNAMIC_BUILDS=0
while IFS=$'\t' read -r raw_id design config; do
  build_dir="${RESULT_DIR}/builds/${raw_id}"
  build_log="${RESULT_DIR}/build-logs/${raw_id}.log"
  echo "[build] ${raw_id} design=${design}"
  set +e
  env \
    ARBITER_BUILD_DIR="${ARBITER_BUILD_DIR}" \
    ARBITER_BENCH_BUILD_DIR="${build_dir}" \
    ARBITER_XINDEX_EXPERIMENT=hotset \
    ARBITER_HOTSET_CONFIG="${config}" \
    ARBITER_BUILD_XINDEX_NATIVE=0 \
    ARBITER_LLVM_PLUGIN="${PLUGIN}" \
    ARBITER_RUNTIME_LIB="${RUNTIME_LIB}" \
    CLANGXX="${CLANGXX}" OPT="${OPT}" \
    LD_LIBRARY_PATH="${LLVM_TOOL_LD_LIBRARY_PATH}" \
    LIBRARY_PATH="${LLVM_TOOL_LIBRARY_PATH}" \
    CPLUS_INCLUDE_PATH="${LLVM_TOOL_CPLUS_INCLUDE_PATH}" \
    MKL_INCLUDE_DIR="${MKL_INCLUDE_DIR}" \
    MKL_LINK_DIR="${MKL_LINK_DIR}" \
    "${ROOT_DIR}/scripts/build-xindex-llvm.sh" >"${build_log}" 2>&1
  build_rc=$?
  set -e

  report="${build_dir}/ycsb_bench.hotset-sites.csv"
  effective="${build_dir}/ycsb_bench.hotset-effective.opt-args"
  if [[ "${build_rc}" -ne 0 || ! -x "${build_dir}/ycsb_bench-arbiter" || ! -s "${report}" || ! -s "${effective}" ]]; then
    status="build-failed:${build_rc}"
    BUILD_FAILURES=$((BUILD_FAILURES + 1))
    printf '%s,%s,%s,,,,%s,%s\n' "${raw_id}" "${design}" "${status}" "${build_dir}" "${build_log}" >>"${CANDIDATES_CSV}"
    echo "[build-fail] ${raw_id} exit=${build_rc}; continuing"
    continue
  fi

  nonconstant_sites="$(awk -F, 'NR > 1 && $12 == "yes" && $7 !~ /^[0-9]+$/ {print $1}' "${report}" | sort -n -u | paste -sd+ -)"
  if [[ -n "${nonconstant_sites}" ]]; then
    status="unsafe-nonconstant-size:${nonconstant_sites}"
    UNSAFE_DYNAMIC_BUILDS=$((UNSAFE_DYNAMIC_BUILDS + 1))
    printf '%s,%s,%s,,,,%s,%s\n' "${raw_id}" "${design}" "${status}" "${build_dir}" "${build_log}" >>"${CANDIDATES_CSV}"
    echo "[build-skip] ${raw_id} selected nonconstant-size site(s): ${nonconstant_sites}"
    continue
  fi

  cp "${NATIVE_BINARY}" "${build_dir}/ycsb_bench-native"
  cp "${config}" "${build_dir}/hotset-build.config"
  static_fp="$(awk -F, 'NR > 1 && $12 == "yes" {print $1}' "${report}" | sort -n -u | paste -sd+ -)"
  selected_sites="$(awk -F, 'NR > 1 && $12 == "yes" {count++} END {print count + 0}' "${report}")"
  if [[ -z "${static_fp}" ]]; then
    status=no-selected-sites
  elif [[ -n "${SEEN_STATIC[${static_fp}]:-}" ]]; then
    status="duplicate-static:${SEEN_STATIC[${static_fp}]}"
  elif [[ "${SELECTED_COUNT}" -ge "${MAX_UNIQUE_CANDIDATES}" ]]; then
    SEEN_STATIC["${static_fp}"]="${raw_id}"
    status=unique-over-cap
  else
    SEEN_STATIC["${static_fp}"]="${raw_id}"
    SELECTED_COUNT=$((SELECTED_COUNT + 1))
    status=selected
    printf '%s,%s,%s,%s,%s,%s,%s\n' "${raw_id}" "${raw_id}" "${design}" "${static_fp}" "${selected_sites}" "${config}" "${build_dir}" >>"${SELECTED_CSV}"
    printf '%s\n' "${raw_id}" >>"${SELECTED_LIST}"
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "${raw_id}" "${design}" "${status}" "${static_fp}" "${selected_sites}" "${config}" "${build_dir}" "${build_log}" >>"${CANDIDATES_CSV}"
done <"${RESULT_DIR}/raw-candidates.tsv"

echo "[build] selected ${SELECTED_COUNT} static-unique candidates; build failures=${BUILD_FAILURES}; unsafe nonconstant builds=${UNSAFE_DYNAMIC_BUILDS}"
printf 'selected_static_unique=%s\nbuild_failures=%s\nunsafe_nonconstant_builds=%s\n' \
  "${SELECTED_COUNT}" "${BUILD_FAILURES}" "${UNSAFE_DYNAMIC_BUILDS}" >>"${MANIFEST}"
if [[ "${SELECTED_COUNT}" -eq 0 ]]; then
  printf 'finished_at=%s\nfinal_status=no-buildable-candidates\n' "$(date '+%F %T %Z')" >>"${MANIFEST}"
  echo "no buildable candidate selected; see ${CANDIDATES_CSV}" >&2
  exit 1
fi

declare -A C_CONFIG=() C_BUILD=() C_STATIC=()
mapfile -t SELECTED_IDS <"${SELECTED_LIST}"
while IFS=, read -r candidate raw_id design static_fp selected_sites config build_dir; do
  [[ "${candidate}" == candidate ]] && continue
  C_CONFIG["${candidate}"]="${config}"
  C_BUILD["${candidate}"]="${build_dir}"
  C_STATIC["${candidate}"]="${static_fp}"
done <"${SELECTED_CSV}"

TIME_EXHAUSTED=0
ROW_SEQUENCE=0
PAIR_SEQUENCE=0
FINALIZED=0
CONTROLLER_PARSE_FAILURES=0

can_start_block() {
  local row_count="$1" duration="$2" now required
  now="$(date +%s)"
  required=$((row_count * (SETUP_BUDGET_SECONDS + duration + COOLDOWN_SECONDS) + FINALIZE_RESERVE_SECONDS))
  if [[ $((now + required)) -gt "${STOP_EPOCH}" ]]; then
    TIME_EXHAUSTED=1
    echo "[deadline] not starting ${row_count} row(s) of ${duration}s; remaining=$((STOP_EPOCH - now))s required=${required}s"
    return 1
  fi
  return 0
}

runtime_fingerprint_from_log() {
  local log="$1" fp
  if [[ ! -s "${log}" ]]; then
    printf none
    return
  fi
  fp="$(awk '
    /^arbiter-arena-site / {
      site=""; allocations=0
      for (i=1; i<=NF; i++) {
        if ($i ~ /^site=/) {split($i,a,"="); site=a[2]}
        if ($i ~ /^allocations=/) {split($i,a,"="); allocations=a[2]}
      }
      if (site != "" && allocations + 0 > 0) print site
    }
  ' "${log}" | sort -n -u | paste -sd+ -)"
  printf '%s' "${fp:-none}"
}

append_synthetic_observation() {
  local phase="$1" candidate="$2" replicate="$3" position="$4" mode="$5"
  local status="$6" driver_rc="$7" duration="$8" sample="$9" row_dir="${10}"
  local static_fp="${11}"
  printf '%s,%s,%s,%s,%s,,%s,,,,,,,,,,,none,%s,,,%s,%s,%s,%s\n' \
    "${phase}" "${candidate}" "${replicate}" "${position}" "${mode}" "${status}" \
    "${static_fp}" "${driver_rc}" "${duration}" "${sample}" "${row_dir}" >>"${OBSERVATIONS}"
}

run_row() {
  local phase="$1" candidate="$2" replicate="$3" requested_mode="$4"
  local duration="$5" sample="$6" config="$7" build_dir="$8" static_fp="$9"
  local run_native=0 run_local=0 run_target=0 row_dir driver_rc row_count
  local row_timeout now remaining runtime_fp log_files

  case "${requested_mode}" in
    native) run_native=1 ;;
    local) run_local=1 ;;
    cxl) run_target=1 ;;
    *) echo "invalid row mode: ${requested_mode}" >&2; exit 1 ;;
  esac

  ROW_SEQUENCE=$((ROW_SEQUENCE + 1))
  row_dir="${RESULT_DIR}/rows/$(printf '%03d' "${ROW_SEQUENCE}")-${phase}-${candidate}-r$(printf '%02d' "${replicate}")-${requested_mode}"
  mkdir -p "$(dirname "${row_dir}")"
  now="$(date +%s)"
  remaining=$((STOP_EPOCH - now - FINALIZE_RESERVE_SECONDS))
  row_timeout=$((duration + ROW_TIMEOUT_OVERHEAD_SECONDS))
  if [[ "${row_timeout}" -gt "${remaining}" ]]; then row_timeout="${remaining}"; fi
  if [[ "${row_timeout}" -le "${duration}" ]]; then
    TIME_EXHAUSTED=1
    append_synthetic_observation "${phase}" "${candidate}" "${replicate}" "${ROW_SEQUENCE}" "${requested_mode}" deadline-before-row 125 "${duration}" "${sample}" "${row_dir}" "${static_fp}"
    return
  fi

  echo "[row ${ROW_SEQUENCE}] phase=${phase} candidate=${candidate} replicate=${replicate} mode=${requested_mode} duration=${duration}s timeout=${row_timeout}s"
  set +e
  timeout --signal=TERM --kill-after=30s "${row_timeout}s" \
    env \
      RESULT_DIR="${row_dir}" \
      HOTSET_BUILD_DIR="${build_dir}" \
      XINDEX_SCALE_DATA_DIR="${DATA_DIR}" \
      XINDEX_SCALE_LOAD_RECORDS="${LOAD_RECORDS}" \
      XINDEX_SCALE_TX_OPS="${TX_OPS}" \
      XINDEX_DURATION_SECONDS="${duration}" \
      XINDEX_THROUGHPUT_SAMPLE_SECONDS="${sample}" \
      XINDEX_FG="${XINDEX_FG}" XINDEX_BG="${XINDEX_BG}" \
      YCSB_TYPES=a REPEATS=1 \
      ARBITER_CPU_NODE="${CPU_NODE}" \
      ARBITER_MEM_NODE="${MEM_NODE}" \
      ARBITER_TARGET_NODE="${TARGET_NODE}" \
      ARBITER_HEAP_BACKEND=arena \
      ARBITER_HOTSET_CONFIG="${config}" \
      ARBITER_ARENA_SLAB_BYTES="${ARENA_SLAB_BYTES}" \
      ARBITER_ARENA_RESERVE_BYTES="${ARENA_RESERVE_BYTES}" \
      ARBITER_ARENA_SLOT_ALIGNMENT="${ARENA_SLOT_ALIGNMENT}" \
      ARBITER_ARENA_STRICT=1 ARBITER_ARENA_REPORT=1 \
      MEMORY_MAX="${MEMORY_MAX}" MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX}" \
      RUN_NATIVE="${run_native}" RUN_LOCAL="${run_local}" RUN_TARGET="${run_target}" \
      PREPARE_SCALE_DATA=0 BUILD_BENCHMARKS=0 FAIL_FAST=1 \
      COOLDOWN_SECONDS=0 USE_SYSTEMD_SCOPE=1 \
      MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR}" \
      LD_LIBRARY_PATH= LIBRARY_PATH= CPLUS_INCLUDE_PATH= \
      "${ROOT_DIR}/scripts/run-protected-hotset-experiment.sh"
  driver_rc=$?
  set -e

  shopt -s nullglob
  log_files=("${row_dir}"/logs/*.log)
  shopt -u nullglob
  runtime_fp=none
  if [[ "${requested_mode}" == native ]]; then
    runtime_fp=native
  elif [[ "${#log_files[@]}" -eq 1 ]]; then
    runtime_fp="$(runtime_fingerprint_from_log "${log_files[0]}")"
  fi

  row_count=0
  if [[ -s "${row_dir}/runs.csv" ]]; then
    if ! row_count="$(awk 'END {print (NR > 0 ? NR - 1 : 0)}' "${row_dir}/runs.csv")"; then
      row_count=parse-error
      CONTROLLER_PARSE_FAILURES=$((CONTROLLER_PARSE_FAILURES + 1))
      echo "[controller-error] failed to count rows in ${row_dir}/runs.csv" >&2
    fi
  fi
  if [[ "${row_count}" =~ ^[0-9]+$ && "${row_count}" -eq 1 ]]; then
    if ! awk -F, -v OFS=, \
      -v phase="${phase}" -v candidate="${candidate}" -v replicate="${replicate}" \
      -v position="${ROW_SEQUENCE}" -v requested="${requested_mode}" \
      -v runtime_fp="${runtime_fp}" -v static_fp="${static_fp}" \
      -v driver_rc="${driver_rc}" -v duration="${duration}" -v sample="${sample}" \
      -v result_dir="${row_dir}" '
        NR == 2 {
          print phase,candidate,replicate,position,requested,$5,$20,$14,$15,$17,
                $26,$27,$28,$29,$31,$32,$33,runtime_fp,static_fp,$13,$16,
                driver_rc,duration,sample,result_dir
        }
      ' "${row_dir}/runs.csv" >>"${OBSERVATIONS}"; then
      CONTROLLER_PARSE_FAILURES=$((CONTROLLER_PARSE_FAILURES + 1))
      append_synthetic_observation "${phase}" "${candidate}" "${replicate}" "${ROW_SEQUENCE}" "${requested_mode}" row-parse-error "${driver_rc}" "${duration}" "${sample}" "${row_dir}" "${static_fp}"
      echo "[controller-error] failed to parse ${row_dir}/runs.csv" >&2
    fi
  else
    append_synthetic_observation "${phase}" "${candidate}" "${replicate}" "${ROW_SEQUENCE}" "${requested_mode}" "row-accounting-${row_count}" "${driver_rc}" "${duration}" "${sample}" "${row_dir}" "${static_fp}"
  fi

  if [[ -s "${row_dir}/throughput-samples.csv" ]]; then
    if ! awk -v OFS=, \
      -v phase="${phase}" -v candidate="${candidate}" -v replicate="${replicate}" \
      -v position="${ROW_SEQUENCE}" -v requested="${requested_mode}" '
        NR > 1 {print phase,candidate,replicate,position,requested,$0}
      ' "${row_dir}/throughput-samples.csv" >>"${ALL_SAMPLES}"; then
      CONTROLLER_PARSE_FAILURES=$((CONTROLLER_PARSE_FAILURES + 1))
      echo "[controller-error] failed to parse ${row_dir}/throughput-samples.csv" >&2
    fi
  fi

  last_status="$(awk -F, 'END {print $7}' "${OBSERVATIONS}")"
  last_throughput="$(awk -F, 'END {print $8}' "${OBSERVATIONS}")"
  echo "[row-done] status=${last_status} throughput=${last_throughput:-none} runtime_sites=${runtime_fp} driver_exit=${driver_rc}"
  if [[ "${COOLDOWN_SECONDS}" -gt 0 ]]; then sleep "${COOLDOWN_SECONDS}"; fi
}

run_pair() {
  local phase="$1" candidate="$2" replicate="$3" duration="$4" sample="$5"
  local -a order
  if ! can_start_block 2 "${duration}"; then return 1; fi
  if [[ $((PAIR_SEQUENCE % 2)) -eq 0 ]]; then order=(local cxl); else order=(cxl local); fi
  PAIR_SEQUENCE=$((PAIR_SEQUENCE + 1))
  for mode in "${order[@]}"; do
    run_row "${phase}" "${candidate}" "${replicate}" "${mode}" "${duration}" "${sample}" \
      "${C_CONFIG[${candidate}]}" "${C_BUILD[${candidate}]}" "${C_STATIC[${candidate}]}"
    if [[ "${CONTROLLER_PARSE_FAILURES}" -gt 0 ]]; then return 2; fi
  done
}

run_native_anchor() {
  local phase="$1" replicate="$2"
  if ! can_start_block 1 "${NATIVE_DURATION}"; then return 1; fi
  run_row "${phase}" native "${replicate}" native "${NATIVE_DURATION}" "${NATIVE_SAMPLE}" \
    "${NATIVE_CONFIG}" "${NATIVE_BUILD_DIR}" native
}

write_phase1_summary() {
  awk -F, -v OFS=, -v local_node="${MEM_NODE}" -v cxl_node="${TARGET_NODE}" '
    NR == 1 {next}
    $1 == "screen" && ($5 == "local" || $5 == "cxl") {
      c=$2; m=$5
      if (!(c in seen)) {seen[c]=1; order[++n]=c}
      status[c,m]=$7; ops[c,m]=$8+0; rss[c,m]=$9+0; swaps[c,m]=$10
      alloc[c,m]=$11; fallback[c,m]=$14; resident[c,m]=$15+0
      majority[c,m]=$16; query[c,m]=$17; fp[c,m]=$18; static[c]=$19
    }
    END {
      print "candidate,safe,reason,local_status,cxl_status,local_ops,cxl_ops,cxl_over_local_pct,runtime_fingerprint,static_fingerprint,local_max_rss_kb,cxl_max_rss_kb,cxl_resident_bytes,cxl_resident_over_rss_pct,local_allocations,cxl_allocations"
      for (i=1; i<=n; i++) {
        c=order[i]; safe=1; reason="ok"; runtime=fp[c,"local"]
        if (status[c,"local"] == "arena-report-missing" && status[c,"cxl"] == "arena-report-missing" && fp[c,"local"] == "none" && fp[c,"cxl"] == "none") {
          safe=0; reason="no-arena-activity"
        } else if (status[c,"local"] != "ok" || status[c,"cxl"] != "ok") {
          safe=0; reason="row-status"
        } else if (fp[c,"local"] == "" || fp[c,"local"] == "none" || fp[c,"local"] != fp[c,"cxl"]) {
          safe=0; reason="runtime-fingerprint"
        } else if (swaps[c,"local"] != "0" || swaps[c,"cxl"] != "0") {
          safe=0; reason="swap"
        } else if (fallback[c,"local"] != "0" || fallback[c,"cxl"] != "0") {
          safe=0; reason="arena-fallback"
        } else if (query[c,"local"] != "0" || query[c,"cxl"] != "0") {
          safe=0; reason="placement-query"
        } else if (majority[c,"local"] != local_node || majority[c,"cxl"] != cxl_node) {
          safe=0; reason="placement-node"
        } else if (ops[c,"local"] <= 0 || ops[c,"cxl"] <= 0) {
          safe=0; reason="throughput"
        }
        delta=(ops[c,"local"] > 0 ? 100*(ops[c,"cxl"]/ops[c,"local"]-1) : 0)
        ratio=(rss[c,"cxl"] > 0 ? 100*resident[c,"cxl"]/(rss[c,"cxl"]*1024) : 0)
        if (fp[c,"local"] != fp[c,"cxl"]) runtime=fp[c,"local"] "|" fp[c,"cxl"]
        print c,safe,reason,status[c,"local"],status[c,"cxl"],ops[c,"local"],ops[c,"cxl"],delta,runtime,static[c],rss[c,"local"],rss[c,"cxl"],resident[c,"cxl"],ratio,alloc[c,"local"],alloc[c,"cxl"]
      }
    }
  ' "${OBSERVATIONS}" >"${RESULT_DIR}/phase1-summary.csv"
}

write_phase1_ranking() {
  awk -F, -v floor="${SCREEN_MIN_DELTA_PCT}" \
    'NR > 1 && $2 == 1 && ($8 + 0) >= floor {print $1 "," $8 "," $9}' \
    "${RESULT_DIR}/phase1-summary.csv" \
    | sort -t, -k2,2nr -k1,1 >"${RESULT_DIR}/phase1-eligible.tmp"
  awk -F, -v cap="${MAX_CONFIRM_PER_RUNTIME_FINGERPRINT}" \
    'seen[$3] < cap {seen[$3]++; print}' "${RESULT_DIR}/phase1-eligible.tmp" \
    >"${RESULT_DIR}/phase1-ranked.tmp"
  {
    echo 'rank,candidate,cxl_over_local_pct,runtime_fingerprint'
    awk -F, -v OFS= '{print NR,$1,$2,$3}' "${RESULT_DIR}/phase1-ranked.tmp"
  } >"${RESULT_DIR}/phase1-ranking.csv"
  awk -F, -v limit="${TOP_CONFIRM}" 'NR > 1 && count < limit {print $2; count++}' \
    "${RESULT_DIR}/phase1-ranking.csv" >"${RESULT_DIR}/promoted-confirm.txt"
}

write_repeated_summary() {
  local candidate_file="$1" expected_pairs="$2" output="$3"
  if [[ ! -s "${candidate_file}" ]]; then
    echo 'candidate,safe,reason,pairs,local_rows,cxl_rows,mean_local_ops,mean_cxl_ops,mean_paired_delta_pct,stddev_paired_delta_pct,cxl_wins,runtime_fingerprint,mean_cxl_resident_bytes,mean_cxl_resident_over_rss_pct,max_rss_kb' >"${output}"
    return
  fi
  awk -F, -v OFS=, -v expected="${expected_pairs}" -v local_node="${MEM_NODE}" -v cxl_node="${TARGET_NODE}" '
    FNR == NR {
      if ($1 != "") {want[$1]=1; order[++n]=$1}
      next
    }
    FNR == 1 {next}
    ($2 in want) && ($5 == "local" || $5 == "cxl") {
      c=$2; m=$5; r=$3+0; key=c SUBSEP r
      rows[c,m]++
      if ($7 != "ok") bad[c]=1
      if ($10 != "0" || $14 != "0" || $17 != "0") bad_safety[c]=1
      if ((m == "local" && $16 != local_node) || (m == "cxl" && $16 != cxl_node)) bad_placement[c]=1
      if ($18 == "" || $18 == "none") bad_fp[c]=1
      if (!(c in base_fp)) base_fp[c]=$18
      else if (base_fp[c] != $18) bad_fp[c]=1
      value=$8+0
      if (value > 0) {
        throughput[key,m]=value
        sum_ops[c,m]+=value
        valid_ops[c,m]++
      }
      if ($9+0 > max_rss[c]) max_rss[c]=$9+0
      if (m == "cxl") {
        resident_sum[c]+=$15+0
        resident_n[c]++
        if ($9+0 > 0) {ratio_sum[c]+=100*($15+0)/(($9+0)*1024); ratio_n[c]++}
      }
    }
    END {
      print "candidate,safe,reason,pairs,local_rows,cxl_rows,mean_local_ops,mean_cxl_ops,mean_paired_delta_pct,stddev_paired_delta_pct,cxl_wins,runtime_fingerprint,mean_cxl_resident_bytes,mean_cxl_resident_over_rss_pct,max_rss_kb"
      for (i=1; i<=n; i++) {
        c=order[i]; pairs=0; delta_sum=0; delta_sumsq=0; wins=0
        for (r=1; r<=expected; r++) {
          key=c SUBSEP r
          if (throughput[key,"local"] > 0 && throughput[key,"cxl"] > 0) {
            delta=100*(throughput[key,"cxl"]/throughput[key,"local"]-1)
            pairs++; delta_sum+=delta; delta_sumsq+=delta*delta
            if (delta > 0) wins++
          }
        }
        safe=1; reason="ok"
        if (rows[c,"local"] != expected || rows[c,"cxl"] != expected || pairs != expected) {safe=0; reason="incomplete"}
        else if (bad[c]) {safe=0; reason="row-status"}
        else if (bad_safety[c]) {safe=0; reason="swap-fallback-query"}
        else if (bad_placement[c]) {safe=0; reason="placement-node"}
        else if (bad_fp[c]) {safe=0; reason="runtime-fingerprint"}
        local_mean=(valid_ops[c,"local"] ? sum_ops[c,"local"]/valid_ops[c,"local"] : 0)
        cxl_mean=(valid_ops[c,"cxl"] ? sum_ops[c,"cxl"]/valid_ops[c,"cxl"] : 0)
        delta_mean=(pairs ? delta_sum/pairs : 0)
        variance=(pairs > 1 ? (delta_sumsq-delta_sum*delta_sum/pairs)/(pairs-1) : 0)
        if (variance < 0) variance=0
        resident_mean=(resident_n[c] ? resident_sum[c]/resident_n[c] : 0)
        ratio_mean=(ratio_n[c] ? ratio_sum[c]/ratio_n[c] : 0)
        print c,safe,reason,pairs,rows[c,"local"]+0,rows[c,"cxl"]+0,local_mean,cxl_mean,delta_mean,sqrt(variance),wins,base_fp[c],resident_mean,ratio_mean,max_rss[c]+0
      }
    }
  ' "${candidate_file}" "${OBSERVATIONS}" >"${output}"
}

write_repeated_ranking() {
  local summary="$1" output="$2" promote_count="$3" promote_file="$4"
  local min_delta="$5" per_runtime_cap="$6"
  awk -F, -v floor="${min_delta}" \
    'NR > 1 && $2 == 1 && ($9 + 0) >= floor {print $1 "," $9 "," $12}' "${summary}" \
    | sort -t, -k2,2nr -k1,1 >"${output}.eligible.tmp"
  awk -F, -v cap="${per_runtime_cap}" \
    'seen[$3] < cap {seen[$3]++; print}' "${output}.eligible.tmp" >"${output}.tmp"
  {
    echo 'rank,candidate,mean_paired_delta_pct,runtime_fingerprint'
    awk -F, -v OFS=, '{print NR,$1,$2,$3}' "${output}.tmp"
  } >"${output}"
  awk -F, -v limit="${promote_count}" 'NR > 1 && count < limit {print $2; count++}' "${output}" >"${promote_file}"
}

write_native_summary() {
  awk -F, -v OFS=, '
    NR == 1 {next}
    $2 == "native" {
      print $1,$3,$7,$8,$9,$10,$20,$21,$25
      if ($7 == "ok" && $8+0 > 0) {n++; sum+=$8; sumsq+=$8*$8}
    }
    END {
      mean=(n ? sum/n : 0)
      variance=(n > 1 ? (sumsq-sum*sum/n)/(n-1) : 0)
      if (variance < 0) variance=0
      print "aggregate",n,"ok",mean,"","","",sqrt(variance),""
    }
  ' "${OBSERVATIONS}" | {
    echo 'phase,replicate,status,throughput,max_rss_kb,swaps,time_sec,wall_time_or_stddev,result_dir'
    cat
  } >"${RESULT_DIR}/native-summary.csv"
}

finalize() {
  local final_status="$1" rows_recorded=parse-error
  if [[ "${FINALIZED}" -eq 1 ]]; then return; fi
  FINALIZED=1
  if [[ -s "${OBSERVATIONS}" ]] && ! write_native_summary; then
    CONTROLLER_PARSE_FAILURES=$((CONTROLLER_PARSE_FAILURES + 1))
    echo "[controller-error] failed to write native summary" >&2
  fi
  if ! rows_recorded="$(awk 'END {print (NR > 0 ? NR - 1 : 0)}' "${OBSERVATIONS}")"; then
    CONTROLLER_PARSE_FAILURES=$((CONTROLLER_PARSE_FAILURES + 1))
    echo "[controller-error] failed to count final observations" >&2
  fi
  if [[ "${CONTROLLER_PARSE_FAILURES}" -gt 0 ]]; then final_status=controller-parse-error; fi
  printf 'finished_at=%s\nfinal_status=%s\nrows_recorded=%s\ncontroller_parse_failures=%s\n' \
    "$(date '+%F %T %Z')" "${final_status}" "${rows_recorded}" \
    "${CONTROLLER_PARSE_FAILURES}" >>"${MANIFEST}"
  cat <<EOF

Broad hot-set sweep finished: ${final_status}
  result:             ${RESULT_DIR}
  candidates:         ${CANDIDATES_CSV}
  observations:       ${OBSERVATIONS}
  throughput samples: ${ALL_SAMPLES}
  phase 1:            ${RESULT_DIR}/phase1-summary.csv
  confirmation:       ${RESULT_DIR}/phase2-summary.csv
  final:              ${RESULT_DIR}/final-summary.csv
  native anchors:     ${RESULT_DIR}/native-summary.csv
EOF
}

abort_on_controller_parse_failure() {
  if [[ "${CONTROLLER_PARSE_FAILURES}" -eq 0 ]]; then return; fi
  echo "[controller-error] aborting promotion after ${CONTROLLER_PARSE_FAILURES} parsing failure(s)" >&2
  finalize controller-parse-error
  exit 1
}

on_signal() {
  echo "[signal] controller interrupted; preserving partial results"
  finalize interrupted
  exit 130
}
trap on_signal INT TERM

echo "[phase] native start anchor"
run_native_anchor native-start 1 || true
abort_on_controller_parse_failure

echo "[phase] screen: ${#SELECTED_IDS[@]} static-unique candidates"
for candidate in "${SELECTED_IDS[@]}"; do
  if ! run_pair screen "${candidate}" 1 "${SCREEN_DURATION}" "${SCREEN_SAMPLE}"; then break; fi
done
abort_on_controller_parse_failure
write_phase1_summary
write_phase1_ranking

echo "[phase] native middle anchor"
if [[ "${TIME_EXHAUSTED}" -eq 0 ]]; then run_native_anchor native-middle 2 || true; fi
abort_on_controller_parse_failure

mapfile -t CONFIRM_IDS <"${RESULT_DIR}/promoted-confirm.txt"
echo "[phase] confirmation: ${#CONFIRM_IDS[@]} broad survivors (up to ${MAX_CONFIRM_PER_RUNTIME_FINGERPRINT} per runtime site set)"
if [[ "${TIME_EXHAUSTED}" -eq 0 ]]; then
  for candidate in "${CONFIRM_IDS[@]}"; do
    for ((replicate=2; replicate<=CONFIRM_EXTRA_PAIRS+1; replicate++)); do
      if ! run_pair confirm "${candidate}" "${replicate}" "${CONFIRM_DURATION}" "${CONFIRM_SAMPLE}"; then break 2; fi
    done
  done
fi
abort_on_controller_parse_failure
write_repeated_summary "${RESULT_DIR}/promoted-confirm.txt" $((CONFIRM_EXTRA_PAIRS + 1)) "${RESULT_DIR}/phase2-summary.csv"
write_repeated_ranking "${RESULT_DIR}/phase2-summary.csv" "${RESULT_DIR}/phase2-ranking.csv" \
  "${TOP_FINAL}" "${RESULT_DIR}/promoted-final.txt" "${CONFIRM_MIN_DELTA_PCT}" \
  "${MAX_FINAL_PER_RUNTIME_FINGERPRINT}"

mapfile -t FINAL_IDS <"${RESULT_DIR}/promoted-final.txt"
echo "[phase] final: ${#FINAL_IDS[@]} candidates"
if [[ "${TIME_EXHAUSTED}" -eq 0 ]]; then
  for candidate in "${FINAL_IDS[@]}"; do
    first_final_rep=$((CONFIRM_EXTRA_PAIRS + 2))
    last_final_rep=$((CONFIRM_EXTRA_PAIRS + FINAL_EXTRA_PAIRS + 1))
    for ((replicate=first_final_rep; replicate<=last_final_rep; replicate++)); do
      if ! run_pair final "${candidate}" "${replicate}" "${FINAL_DURATION}" "${FINAL_SAMPLE}"; then break 2; fi
    done
  done
fi
abort_on_controller_parse_failure
write_repeated_summary "${RESULT_DIR}/promoted-final.txt" $((CONFIRM_EXTRA_PAIRS + FINAL_EXTRA_PAIRS + 1)) "${RESULT_DIR}/final-summary.csv"
write_repeated_ranking "${RESULT_DIR}/final-summary.csv" "${RESULT_DIR}/final-ranking.csv" \
  "${TOP_FINAL}" "${RESULT_DIR}/finalists.txt" -1000000000 \
  "${MAX_FINAL_PER_RUNTIME_FINGERPRINT}"

echo "[phase] native end anchor"
if [[ "${TIME_EXHAUSTED}" -eq 0 ]]; then run_native_anchor native-end 3 || true; fi
abort_on_controller_parse_failure

if [[ "${TIME_EXHAUSTED}" -eq 1 ]]; then
  finalize deadline-partial
else
  finalize complete
fi
