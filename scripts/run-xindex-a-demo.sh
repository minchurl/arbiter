#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
[[ $# == 0 ]] || { echo "usage: $0 (no arguments)" >&2; exit 1; }

# 1. A: read 50% / update 50%. Automatic policy; no pinned site IDs.
export YCSB_TYPE=a
export ARBITER_HITM_SEED_CONFIG="${ROOT_DIR}/configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config"
export ARBITER_CPU_NODE=0 ARBITER_MEM_NODE=0 ARBITER_TARGET_NODE=2
export RUN_NATIVE=0 XINDEX_CORRECTNESS_FULL_REPEATS=1 BUILD_BENCHMARKS=1
export XINDEX_CORRECTNESS_FULL_BUILD_DIR="${ROOT_DIR}/build/arbiter-bench/xindex-a-demo-build"
export XINDEX_CORRECTNESS_FULL_RESULT_DIR="${ROOT_DIR}/build/arbiter-bench/xindex-a-demo-$(date +%Y%m%d-%H%M%S)"

# 2. Build, then Local (node 0) once, then CXL (node 2) once.
# Each: 100M load + 400M transactions to completion; no time limit or replay.
# Runner fixes 31+1 workers, MemoryMax=64G, no swap, and post-timing validation.
echo "YCSB-A: Local -> CXL, one full trace pass each (31+1 workers, 64G cap)."
./scripts/validate-xindex-runtime-correctness-full.sh

# 3. Print measured throughput and whole-process peak RSS (KiB -> GiB).
awk -F, '
  $3 == "hitm-seed-local"  {local_rate = $7; local_rss = $8}
  $3 == "hitm-seed-target" {cxl_rate = $7; cxl_rss = $8}
  END {
    printf "\nYCSB-A result\nLocal: %.3fM tx/s\nCXL:   %.3fM tx/s\nCXL/Local: %+.2f%%\n", local_rate / 1e6, cxl_rate / 1e6, (cxl_rate / local_rate - 1) * 100
    printf "Peak process RSS: Local %.3f GiB; CXL %.3f GiB (includes setup and validation)\n", local_rss / 1048576, cxl_rss / 1048576
  }
' "${XINDEX_CORRECTNESS_FULL_RESULT_DIR}/summary.csv"
echo "Logs: ${XINDEX_CORRECTNESS_FULL_RESULT_DIR}"
