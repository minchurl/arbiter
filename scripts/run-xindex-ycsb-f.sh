#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# Automatic policy; the compiler/runtime and allocation policy are shared with A.
export ARBITER_HITM_SEED_CONFIG="${ROOT_DIR}/configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config"
export YCSB_TYPE=f
export ARBITER_CPU_NODE=0 ARBITER_MEM_NODE=0 ARBITER_TARGET_NODE=2
export RUN_NATIVE=1 BUILD_BENCHMARKS=1
export XINDEX_CORRECTNESS_FULL_REPEATS="${REPEATS:-1}"
export XINDEX_CORRECTNESS_FULL_BUILD_DIR="${ROOT_DIR}/build/arbiter-bench/xindex-ycsb-f-build"
export XINDEX_CORRECTNESS_FULL_RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-ycsb-f-$(date +%Y%m%d-%H%M%S)}"

if [[ "${1:-}" == "--smoke" && $# == 1 ]]; then
  mkdir -p "${XINDEX_CORRECTNESS_FULL_BUILD_DIR}"
  "${CXX:-c++}" -std=c++14 -Wall -Wextra \
    -Ibenchmark/xindex/XIndex-H tests/xindex/ycsb-rmw.cpp \
    -o "${XINDEX_CORRECTNESS_FULL_BUILD_DIR}/ycsb-rmw-test"
  "${XINDEX_CORRECTNESS_FULL_BUILD_DIR}/ycsb-rmw-test"
  exec env ARBITER_BENCH_BUILD_DIR="${XINDEX_CORRECTNESS_FULL_BUILD_DIR}" \
    XINDEX_CORRECTNESS_RESULT_DIR="${XINDEX_CORRECTNESS_FULL_RESULT_DIR}-smoke" \
    XINDEX_EXPECTED_RUNTIME_SITES=auto \
    "${ROOT_DIR}/scripts/validate-xindex-runtime-correctness.sh"
fi

echo "YCSB-F: A trace READ stays READ; UPDATE becomes same-worker get + put."
echo "One F transaction counts once; the log also reports actual get/put calls."
echo "Native / selected-Local / selected-CXL; 31+1 workers; MemoryMax=64G."
"${ROOT_DIR}/scripts/validate-xindex-runtime-correctness-full.sh" "$@"
if [[ "${1:-}" != "--check" && "${1:-}" != "--help" && "${1:-}" != "-h" ]]; then
  echo
  awk -F, 'NR > 1 {printf "%s: %.3fM transactions/s\n", $3, $7 / 1000000}' \
    "${XINDEX_CORRECTNESS_FULL_RESULT_DIR}/summary.csv"
  echo "Details: ${XINDEX_CORRECTNESS_FULL_RESULT_DIR}/interpretation.md"
fi
