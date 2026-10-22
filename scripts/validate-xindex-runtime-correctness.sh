#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"
BENCH_DIR="${ARBITER_BENCH_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-runtime-validation}"
DATA_DIR="${XINDEX_CORRECTNESS_DATA_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-correctness-data}"
RESULT_DIR="${XINDEX_CORRECTNESS_RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-runtime-correctness-$(date +%Y%m%d-%H%M%S)}"
LOCAL_NODE="${ARBITER_LOCAL_NODE:-0}"
CXL_NODE="${ARBITER_CXL_NODE:-2}"
CPU_LIST="${XINDEX_CORRECTNESS_CPUS:-0-3}"
FG="${XINDEX_CORRECTNESS_FG:-4}"
BG="${XINDEX_CORRECTNESS_BG:-1}"
CONFIG="${ARBITER_HITM_SEED_CONFIG:-${ROOT_DIR}/configs/hitm-seed/xindex-site68-71-ablation.config}"
EXPECTED_RUNTIME_SITES="${XINDEX_EXPECTED_RUNTIME_SITES:-68,71}"
WORKLOAD="${YCSB_TYPE:-a}"

TINFO_DIR="${ROOT_DIR}/.tools/libtinfo5-root/lib/x86_64-linux-gnu"
LLVM_SHARED_DIR="${ROOT_DIR}/.tools/libllvm18-root/usr/lib/x86_64-linux-gnu"
LLVM_BIN="${ROOT_DIR}/.tools/llvm-18.1.8/bin"
APT_LLVM_BIN="${ROOT_DIR}/.tools/llvm18-apt-root/usr/bin"
TOOL_LD_PATH="${TINFO_DIR}:${LLVM_SHARED_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
TOOL_CPLUS_PATH="/usr/include/c++/11/backward:/usr/include/x86_64-linux-gnu/c++/11:/usr/include/c++/11${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"
RUN_LD_PATH="/opt/intel/oneapi/mkl/latest/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

for command in awk cmake grep numactl sed; do
  command -v "${command}" >/dev/null || {
    echo "missing command: ${command}" >&2
    exit 1
  }
done
for path in \
  "${LLVM_BIN}/clang" \
  "${LLVM_BIN}/clang++" \
  "${APT_LLVM_BIN}/opt-18" \
  "${APT_LLVM_BIN}/llvm-dis-18" \
  "${CONFIG}"; do
  [[ -e "${path}" ]] || {
    echo "missing required path: ${path}" >&2
    exit 1
  }
done
for node in "${LOCAL_NODE}" "${CXL_NODE}"; do
  [[ -d "/sys/devices/system/node/node${node}" ]] || {
    echo "missing NUMA node${node}" >&2
    exit 1
  }
done

mkdir -p "${RESULT_DIR}"
exec > >(tee "${RESULT_DIR}/console.log") 2>&1

echo "[validation] result_dir=${RESULT_DIR}"
echo "[validation] config=${CONFIG} local_node=${LOCAL_NODE} cxl_node=${CXL_NODE} cpus=${CPU_LIST}"

env LD_LIBRARY_PATH="${TOOL_LD_PATH}" \
  cmake --build "${BUILD_DIR}" -j "$(nproc)"

env \
  LD_LIBRARY_PATH="${TOOL_LD_PATH}" \
  LIBRARY_PATH="${ROOT_DIR}/.tools/libstdcxx${LIBRARY_PATH:+:${LIBRARY_PATH}}" \
  CPLUS_INCLUDE_PATH="${TOOL_CPLUS_PATH}" \
  ARBITER_BUILD_DIR="${BUILD_DIR}" \
  CLANG="${LLVM_BIN}/clang" \
  CLANGXX="${LLVM_BIN}/clang++" \
  OPT="${APT_LLVM_BIN}/opt-18" \
  LLVM_DIS="${APT_LLVM_BIN}/llvm-dis-18" \
  "${ROOT_DIR}/scripts/smoke.sh"

for node in "${LOCAL_NODE}" "${CXL_NODE}"; do
  env ARBITER_HEAP_BACKEND=arena ARBITER_ARENA_STRICT=1 \
    ARBITER_TARGET_NODE="${node}" ARBITER_EXPECT_NODE="${node}" \
    "${BUILD_DIR}/bin/arbiter-slab-arena-smoke"
  env ARBITER_HEAP_BACKEND=arena ARBITER_ARENA_STRICT=1 \
    ARBITER_TARGET_NODE="${node}" \
    "${BUILD_DIR}/bin/arbiter-slab-arena-boundary-smoke"
done

XINDEX_CORRECTNESS_DATA_DIR="${DATA_DIR}" \
  "${ROOT_DIR}/scripts/prepare-xindex-correctness-data.sh"

env \
  LD_LIBRARY_PATH="${TOOL_LD_PATH}" \
  LIBRARY_PATH="${ROOT_DIR}/.tools/libstdcxx${LIBRARY_PATH:+:${LIBRARY_PATH}}" \
  CPLUS_INCLUDE_PATH="${TOOL_CPLUS_PATH}" \
  ARBITER_BUILD_DIR="${BUILD_DIR}" \
  ARBITER_BENCH_BUILD_DIR="${BENCH_DIR}" \
  ARBITER_HITM_SEED_CONFIG="${CONFIG}" \
  CLANGXX="${LLVM_BIN}/clang++" \
  OPT="${APT_LLVM_BIN}/opt-18" \
  "${ROOT_DIR}/scripts/build-xindex-llvm.sh"

LOAD_PATH="${DATA_DIR}/xindex_load_ycsb_a.correctness.dat"
TX_PATH="${DATA_DIR}/xindex_transaction_ycsb_a.correctness.dat"
COMMON_ARGS=(
  --fg "${FG}"
  --bg "${BG}"
  --iteration 1
  --ycsb_type "${WORKLOAD}"
  --ycsb-load "${LOAD_PATH}"
)

run_native() {
  local name="${1:-native}"
  local tx_path="${2:-${TX_PATH}}"
  echo "[validation] run=${name}"
  env LD_LIBRARY_PATH="${RUN_LD_PATH}" XINDEX_VALIDATE=1 \
    XINDEX_REQUIRE_ALL_OPERATIONS_SUCCESS=1 \
    numactl --physcpubind="${CPU_LIST}" --membind="${LOCAL_NODE}" \
    "${BENCH_DIR}/ycsb_bench-native" "${COMMON_ARGS[@]}" --ycsb-tx "${tx_path}" \
    >"${RESULT_DIR}/${name}.log" 2>&1
  grep -E 'xindex-(operation|state)-validation|Throughput\(op/s\)' \
    "${RESULT_DIR}/${name}.log"
}

run_arbiter() {
  local name="$1"
  local target_node="$2"
  echo "[validation] run=${name} target_node=${target_node}"
  env LD_LIBRARY_PATH="${RUN_LD_PATH}" XINDEX_VALIDATE=1 \
    XINDEX_REQUIRE_ALL_OPERATIONS_SUCCESS=1 \
    ARBITER_HEAP_BACKEND=arena ARBITER_ARENA_STRICT=1 \
    ARBITER_ARENA_REPORT=1 ARBITER_TARGET_NODE="${target_node}" \
    numactl --physcpubind="${CPU_LIST}" --membind="${LOCAL_NODE}" \
    "${BENCH_DIR}/ycsb_bench-arbiter" "${COMMON_ARGS[@]}" --ycsb-tx "${TX_PATH}" \
    >"${RESULT_DIR}/${name}.log" 2>&1
  grep -E 'xindex-(operation|state)-validation|Throughput\(op/s\)|arbiter-arena-(site|summary|residency)' \
    "${RESULT_DIR}/${name}.log"
}

run_native
run_arbiter local "${LOCAL_NODE}"
run_arbiter cxl "${CXL_NODE}"

for log in native local cxl; do
  grep -q 'xindex-operation-validation .* failed=0 ' \
    "${RESULT_DIR}/${log}.log"
  grep -q 'xindex-state-validation .* failed_reads=0 ' \
    "${RESULT_DIR}/${log}.log"
done
for log in local cxl; do
  grep -q 'arbiter-arena-summary .*fallback_allocations=0 ' \
    "${RESULT_DIR}/${log}.log"
done

operation_line() {
  grep '^xindex-operation-validation ' "$1" | tail -1
}
native_operations="$(operation_line "${RESULT_DIR}/native.log")"
local_operations="$(operation_line "${RESULT_DIR}/local.log")"
cxl_operations="$(operation_line "${RESULT_DIR}/cxl.log")"
if [[ -z "${native_operations}" ||
      "${native_operations}" != "${local_operations}" ||
      "${native_operations}" != "${cxl_operations}" ]]; then
  echo "operation-result mismatch across native/Local/CXL" >&2
  exit 1
fi

runtime_sites() {
  awk '/^arbiter-arena-site / {
    for (i = 1; i <= NF; ++i) {
      if ($i ~ /^site=/) {
        split($i, field, "=")
        print field[2]
      }
    }
  }' "$1" | sort -n | paste -sd, -
}
local_sites="$(runtime_sites "${RESULT_DIR}/local.log")"
cxl_sites="$(runtime_sites "${RESULT_DIR}/cxl.log")"
if [[ -z "${local_sites}" || "${local_sites}" != "${cxl_sites}" ||
      ( "${EXPECTED_RUNTIME_SITES}" != "auto" &&
        "${local_sites}" != "${EXPECTED_RUNTIME_SITES}" ) ]]; then
  echo "runtime site mismatch: expected=${EXPECTED_RUNTIME_SITES} local=${local_sites} cxl=${cxl_sites}" >&2
  exit 1
fi

digest() {
  sed -n 's/.*xindex-state-validation.*digest=\([^ ]*\).*/\1/p' "$1" | tail -1
}
native_digest="$(digest "${RESULT_DIR}/native.log")"
local_digest="$(digest "${RESULT_DIR}/local.log")"
cxl_digest="$(digest "${RESULT_DIR}/cxl.log")"
if [[ -z "${native_digest}" || "${native_digest}" != "${local_digest}" ||
      "${native_digest}" != "${cxl_digest}" ]]; then
  echo "state digest mismatch: native=${native_digest} local=${local_digest} cxl=${cxl_digest}" >&2
  exit 1
fi

if [[ "${WORKLOAD}" == "f" ]]; then
  # Explicit RMW records must behave identically to the A-trace UPDATE mapping.
  explicit_tx="${RESULT_DIR}/explicit-f.dat"
  awk '$1 == "UPDATE" {$1 = "READMODIFYWRITE"} {print}' "${TX_PATH}" >"${explicit_tx}"
  run_native explicit-f "${explicit_tx}"
  if [[ "$(operation_line "${RESULT_DIR}/explicit-f.log")" != "${native_operations}" ||
        "$(digest "${RESULT_DIR}/explicit-f.log")" != "${native_digest}" ]]; then
    echo "explicit RMW input differs from UPDATE-to-RMW mapping" >&2
    exit 1
  fi
  grep -Eq 'rmw_attempted=[1-9][0-9]* ' "${RESULT_DIR}/native.log"
fi

echo "[validation] PASS digest=${native_digest} result_dir=${RESULT_DIR}"
