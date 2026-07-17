#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOAD_RECORDS="${XINDEX_SCALE_LOAD_RECORDS:-100000}"
TX_OPS="${XINDEX_SCALE_TX_OPS:-400000}"
YCSB_TYPES="${YCSB_TYPES:-${YCSB_TYPE:-a}}"
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/generic-placement-scale-${LOAD_RECORDS}-${TX_OPS}}"
XINDEX_SCALE_DATA_DIR="${XINDEX_SCALE_DATA_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_scale_${LOAD_RECORDS}_${TX_OPS}}"
MEMORY_MAX="${MEMORY_MAX:-64G}"
MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-0}"
USE_SYSTEMD_SCOPE="${USE_SYSTEMD_SCOPE:-1}"

usage() {
  cat <<EOF
usage: $0

Runs a protected, scaled XIndex/YCSB generic placement experiment. This is the
safer first remote-placement run before using the full 46GB raw traces.

Defaults:
  load records:       ${LOAD_RECORDS}
  transaction ops:    ${TX_OPS}
  workloads:          ${YCSB_TYPES}
  result dir:         ${RESULT_DIR}
  scaled data dir:    ${XINDEX_SCALE_DATA_DIR}
  cgroup MemoryMax:   ${MEMORY_MAX}
  MemorySwapMax:      ${MEMORY_SWAP_MAX}

Useful environment:
  XINDEX_SCALE_LOAD_RECORDS  default: 100000
  XINDEX_SCALE_TX_OPS        default: 400000
  YCSB_TYPES                 default: "\${YCSB_TYPE:-a}"
  RESULT_DIR                 default: build/arbiter-bench/generic-placement-scale-<load>-<tx>
  MEMORY_MAX                 default: 64G
  MEMORY_SWAP_MAX            default: 0
  REPEATS                    default: 1
  XINDEX_FG                  default: 8
  XINDEX_ITERATION           default: 3
  XINDEX_CONFIGS             default: "native all-local generic-local all-remote generic-remote"
  BUILD_BENCHMARKS           default: 0
  USE_SYSTEMD_SCOPE          default: 1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "${USE_SYSTEMD_SCOPE}" == "1" && "${PROTECTED_SCOPE_ACTIVE:-0}" != "1" ]]; then
  if ! command -v systemd-run >/dev/null 2>&1; then
    echo "systemd-run is required for protected execution; set USE_SYSTEMD_SCOPE=0 to run unprotected" >&2
    exit 1
  fi

  mkdir -p "${RESULT_DIR}"
  cat <<EOF
Starting protected scope:
  MemoryMax=${MEMORY_MAX}
  MemorySwapMax=${MEMORY_SWAP_MAX}
  result=${RESULT_DIR}
EOF

  exec systemd-run --user --scope \
    -p "MemoryMax=${MEMORY_MAX}" \
    -p "MemorySwapMax=${MEMORY_SWAP_MAX}" \
    env \
      PROTECTED_SCOPE_ACTIVE=1 \
      XINDEX_SCALE_LOAD_RECORDS="${LOAD_RECORDS}" \
      XINDEX_SCALE_TX_OPS="${TX_OPS}" \
      YCSB_TYPES="${YCSB_TYPES}" \
      RESULT_DIR="${RESULT_DIR}" \
      XINDEX_SCALE_DATA_DIR="${XINDEX_SCALE_DATA_DIR}" \
      MEMORY_MAX="${MEMORY_MAX}" \
      MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX}" \
      USE_SYSTEMD_SCOPE="${USE_SYSTEMD_SCOPE}" \
      XINDEX_DATA_DIR="${XINDEX_DATA_DIR:-}" \
      BUILD_BENCHMARKS="${BUILD_BENCHMARKS:-}" \
      RUN_GUPS="${RUN_GUPS:-}" \
      RUN_XINDEX="${RUN_XINDEX:-}" \
      REPEATS="${REPEATS:-}" \
      RERUN_FAILED="${RERUN_FAILED:-}" \
      XINDEX_WORKLOADS="${XINDEX_WORKLOADS:-}" \
      XINDEX_CONFIGS="${XINDEX_CONFIGS:-}" \
      XINDEX_FG="${XINDEX_FG:-}" \
      XINDEX_ITERATION="${XINDEX_ITERATION:-}" \
      ARBITER_CPU_NODE="${ARBITER_CPU_NODE:-}" \
      ARBITER_MEM_NODE="${ARBITER_MEM_NODE:-}" \
      ARBITER_TARGET_NODE="${ARBITER_TARGET_NODE:-}" \
      "$0" "$@"
fi

if [[ "${PROTECTED_SCOPE_ACTIVE:-0}" == "1" ]]; then
  echo 1000 > "/proc/$$/oom_score_adj" 2>/dev/null || true
fi

export XINDEX_SCALE_LOAD_RECORDS="${LOAD_RECORDS}"
export XINDEX_SCALE_TX_OPS="${TX_OPS}"
export YCSB_TYPES="${YCSB_TYPES}"
export XINDEX_SCALE_DATA_DIR="${XINDEX_SCALE_DATA_DIR}"
if [[ -z "${XINDEX_DATA_DIR:-}" ]]; then
  unset XINDEX_DATA_DIR
fi

"${ROOT_DIR}/scripts/prepare-xindex-ycsb-scale-data.sh"

export RESULT_DIR
export XINDEX_DATA_DIR="${XINDEX_SCALE_DATA_DIR}"
export BUILD_BENCHMARKS="${BUILD_BENCHMARKS:-0}"
export RUN_GUPS="${RUN_GUPS:-0}"
export RUN_XINDEX="${RUN_XINDEX:-1}"
export REPEATS="${REPEATS:-1}"
export RERUN_FAILED="${RERUN_FAILED:-0}"
export XINDEX_WORKLOADS="${XINDEX_WORKLOADS:-${YCSB_TYPES}}"
export XINDEX_CONFIGS="${XINDEX_CONFIGS:-native all-local generic-local all-remote generic-remote}"
export XINDEX_FG="${XINDEX_FG:-8}"
export XINDEX_ITERATION="${XINDEX_ITERATION:-3}"

mkdir -p "${RESULT_DIR}"

cat <<EOF
Running scaled XIndex/YCSB placement experiment:
  data=${XINDEX_DATA_DIR}
  result=${RESULT_DIR}
  workloads=${XINDEX_WORKLOADS}
  configs=${XINDEX_CONFIGS}
  repeats=${REPEATS}
  fg=${XINDEX_FG}
  iteration=${XINDEX_ITERATION}
EOF

"${ROOT_DIR}/scripts/run-generic-placement-experiment.sh"

REPORT="${RESULT_DIR}/report.md"
{
  echo "# Protected Scaled XIndex Placement Report"
  echo
  echo "- Generated UTC: $(date -u '+%Y-%m-%d %H:%M:%S')"
  echo "- Result dir: \`${RESULT_DIR}\`"
  echo "- Scaled data dir: \`${XINDEX_DATA_DIR}\`"
  echo "- Workloads: \`${XINDEX_WORKLOADS}\`"
  echo "- Configs: \`${XINDEX_CONFIGS}\`"
  echo "- Repeats: \`${REPEATS}\`"
  echo "- XIndex foreground threads: \`${XINDEX_FG}\`"
  echo "- XIndex iteration: \`${XINDEX_ITERATION}\`"
  echo "- Scale: \`${LOAD_RECORDS}\` load records, \`${TX_OPS}\` transaction ops"
  echo "- Protection: user systemd scope \`MemoryMax=${MEMORY_MAX}\`, \`MemorySwapMax=${MEMORY_SWAP_MAX}\`, benchmark launcher \`oom_score_adj=1000\` when permitted"
  echo
  echo "## Comparison Meaning"
  echo
  echo "- \`native\`: uninstrumented XIndex baseline."
  echo "- \`all-local\`: naive all supported allocation sites rewritten, local memory."
  echo "- \`generic-local\`: shared-mutable heuristic rewritten, local memory."
  echo "- \`all-remote\`: naive all supported allocation sites rewritten, remote target node."
  echo "- \`generic-remote\`: shared-mutable heuristic rewritten, remote target node."
  echo
  echo "## Summary"
  echo
  if [[ -f "${RESULT_DIR}/summary.md" ]]; then
    sed -n '5,$p' "${RESULT_DIR}/summary.md"
  else
    echo "Summary was not generated."
  fi
  echo
  echo "## Relative Results"
  echo
  if [[ -f "${RESULT_DIR}/runs.csv" ]]; then
    awk -F, '
      NR == 1 { next }
      $18 != "ok" { next }
      {
        time[$3] = $13 + 0
        thr[$3] = $14 + 0
        order[++n] = $3
      }
      END {
        if (!("native" in time) || time["native"] == 0 || thr["native"] == 0) {
          print "Native baseline was not available."
          exit
        }

        print "| Config | Time / Native | Throughput / Native |"
        print "|---|---:|---:|"
        for (i = 1; i <= n; i++) {
          config = order[i]
          printf "| %s | %.3fx | %.3fx |\n", config, time[config] / time["native"], thr[config] / thr["native"]
        }

        if (("all-local" in thr) && ("generic-local" in thr) && thr["all-local"] != 0) {
          printf "\n- Heuristic local throughput vs naive local: %.3fx\n", thr["generic-local"] / thr["all-local"]
        }
        if (("all-remote" in thr) && ("generic-remote" in thr) && thr["all-remote"] != 0) {
          printf "- Heuristic remote throughput vs naive remote: %.3fx\n", thr["generic-remote"] / thr["all-remote"]
        }
      }
    ' "${RESULT_DIR}/runs.csv"
  else
    echo "Runs CSV was not generated."
  fi
  echo
  echo "## Notes"
  echo
  echo "This run is intentionally scaled down. Use it to check correctness and relative placement behavior before increasing \`XINDEX_SCALE_LOAD_RECORDS\`, \`XINDEX_SCALE_TX_OPS\`, \`XINDEX_FG\`, \`XINDEX_ITERATION\`, or \`REPEATS\`."
} > "${REPORT}"

echo "wrote ${REPORT}"
