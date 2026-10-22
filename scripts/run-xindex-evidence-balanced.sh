#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

# Automatic policy: no site IDs are pinned. Size is only a +1 tie breaker.
CONFIG="${ROOT_DIR}/configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config"

# One full 400M-operation Local/CXL pair with correctness checks enabled.
RESULT_DIR="${ROOT_DIR}/build/arbiter-bench/xindex-evidence-balanced-$(date +%Y%m%d-%H%M%S)"
BUILD_DIR="${ROOT_DIR}/build/arbiter-bench/xindex-evidence-balanced-build"

echo "XIndex/YCSB-A evidence-balanced experiment"
echo "  policy:       ${CONFIG}"
echo "  workload:     100M load records + 400M operations, one pass"
echo "  comparison:   Local node 0 vs CXL node 2"
echo "  workers:      31 foreground + 1 background"
echo "  safety:       MemoryMax=64G, swap disabled, strict arena"
echo "  correctness:  operation counts + 4,096-key state digest"
echo "  result:       ${RESULT_DIR}"
echo

env \
  ARBITER_HITM_SEED_CONFIG="${CONFIG}" \
  ARBITER_CPU_NODE=0 \
  ARBITER_MEM_NODE=0 \
  ARBITER_TARGET_NODE=2 \
  XINDEX_CORRECTNESS_FULL_RESULT_DIR="${RESULT_DIR}" \
  XINDEX_CORRECTNESS_FULL_BUILD_DIR="${BUILD_DIR}" \
  BUILD_BENCHMARKS=1 \
  "${ROOT_DIR}/scripts/validate-xindex-runtime-correctness-full.sh"

echo
"${ROOT_DIR}/scripts/summarize-xindex-hitm-seed-result.sh" "${RESULT_DIR}"
