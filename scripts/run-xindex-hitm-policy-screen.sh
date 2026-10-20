#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=run
REPLAY_ARG=--quick
REPEATS_LABEL=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE=check
      ;;
    --confirm)
      REPLAY_ARG=
      REPEATS_LABEL="${REPEATS:-4}"
      ;;
    -h|--help)
      cat <<'EOF'
usage: scripts/run-xindex-hitm-policy-screen.sh [--check] [--confirm]

Compares the recommended automatic HITM-risk policy with the balanced-default
control on one complete 400M-operation XIndex/YCSB-A trace.  The default is
one Local/CXL pair per policy.  --confirm uses REPEATS (default 4) pairs per
policy.  The other safe hypothesis configs select the same XIndex sites and
therefore do not need duplicate XIndex performance rows.

Common overrides:
  RESULT_ROOT          unique parent result directory
  REPEATS              pairs per policy with --confirm, default 4
  ARBITER_TARGET_NODE  CXL NUMA node, default 2
  ARBITER_CPU_NODE     benchmark CPU node, default 0
  ARBITER_MEM_NODE     local-memory node, default 0
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

RESULT_ROOT="${RESULT_ROOT:-${ROOT_DIR}/build/arbiter-bench/xindex-hitm-policy-screen-$(date +%Y%m%d-%H%M%S)}"
if [[ "${RESULT_ROOT}" != /* ]]; then
  RESULT_ROOT="${ROOT_DIR}/${RESULT_ROOT}"
fi

POLICY_NAMES=(
  evidence-balanced-size-tiebreaker
  balanced-size-tiebreaker
)
POLICY_CONFIGS=(
  configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config
  configs/hitm-seed/policy-candidates/balanced-size-tiebreaker.config
)

for config in "${POLICY_CONFIGS[@]}"; do
  if [[ ! -s "${ROOT_DIR}/${config}" ]]; then
    echo "missing policy config: ${ROOT_DIR}/${config}" >&2
    exit 1
  fi
done

if [[ "${MODE}" == check ]]; then
  for index in "${!POLICY_NAMES[@]}"; do
    echo "[check] ${POLICY_NAMES[index]}: ${POLICY_CONFIGS[index]}"
    env \
      ARBITER_HITM_SEED_CONFIG="${POLICY_CONFIGS[index]}" \
      HITM_SEED_BUILD_DIR="${RESULT_ROOT}/builds/${POLICY_NAMES[index]}" \
      RESULT_DIR="${RESULT_ROOT}/runs/${POLICY_NAMES[index]}" \
      BUILD_BENCHMARKS=0 \
      "${ROOT_DIR}/scripts/run-xindex-hitm-seed-replay.sh" --check ${REPLAY_ARG:+"${REPLAY_ARG}"}
  done
  echo "check-only mode: no directory, build, or benchmark was started"
  exit 0
fi

if [[ -e "${RESULT_ROOT}" ]]; then
  echo "result root already exists: ${RESULT_ROOT}" >&2
  exit 1
fi
mkdir -p "${RESULT_ROOT}/builds" "${RESULT_ROOT}/runs"

{
  echo "started_at=$(date --iso-8601=seconds)"
  echo "git_commit=$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  echo "git_dirty_files=$(git -C "${ROOT_DIR}" status --porcelain | wc -l)"
  echo "pairs_per_policy=${REPEATS_LABEL}"
  echo "execution_mode=one complete 400M-operation trace per row"
  for index in "${!POLICY_NAMES[@]}"; do
    echo "policy_${index}=${POLICY_NAMES[index]}:${POLICY_CONFIGS[index]}"
  done
} >"${RESULT_ROOT}/screen-manifest.txt"

for index in "${!POLICY_NAMES[@]}"; do
  policy="${POLICY_NAMES[index]}"
  config="${POLICY_CONFIGS[index]}"
  echo "[screen] starting ${policy}"
  env \
    ARBITER_HITM_SEED_CONFIG="${config}" \
    HITM_SEED_BUILD_DIR="${RESULT_ROOT}/builds/${policy}" \
    RESULT_DIR="${RESULT_ROOT}/runs/${policy}" \
    REPEATS="${REPEATS:-4}" \
    BUILD_BENCHMARKS=1 \
    "${ROOT_DIR}/scripts/run-xindex-hitm-seed-replay.sh" ${REPLAY_ARG:+"${REPLAY_ARG}"}
  echo "[screen] completed ${policy}"
done

COMPARISON_CSV="${RESULT_ROOT}/comparison.csv"
printf '%s\n' \
  'policy,selected_seeds,local_ops,cxl_ops,delta_pct,cxl_resident_gib,max_rss_gib,fallbacks,swaps,status,result_dir' \
  >"${COMPARISON_CSV}"

for policy in "${POLICY_NAMES[@]}"; do
  run_dir="${RESULT_ROOT}/runs/${policy}"
  selected="$({
    awk -F, 'NR > 1 && $10 == "seed" && $12 == "yes" {print $1}' \
      "${run_dir}/hitm-seed-sites.csv"
  } | paste -sd+ -)"
  awk -F, -v policy="${policy}" -v selected="${selected}" -v run_dir="${run_dir}" '
    NR > 1 {
      if ($20 != "ok") bad++
      rows++
      fallbacks += $29
      swaps += $17
      if ($15 > max_rss) max_rss = $15
      if ($3 == "hitm-seed-local") { local_sum += $14; local_n++ }
      if ($3 == "hitm-seed-target") {
        target_sum += $14; target_n++
        resident_sum += $31; resident_n++
      }
    }
    END {
      local = local_n ? local_sum / local_n : 0
      target = target_n ? target_sum / target_n : 0
      delta = local > 0 ? (target / local - 1) * 100 : 0
      printf "%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d,%s,%s\n", \
        policy, selected, local, target, delta, \
        (resident_n ? resident_sum / resident_n / 1073741824 : 0), \
        max_rss / 1048576, fallbacks, swaps, \
        (rows > 0 && bad == 0 ? "ok" : "failed"), run_dir
    }
  ' "${run_dir}/runs.csv" >>"${COMPARISON_CSV}"
done

COMPARISON_MD="${RESULT_ROOT}/comparison.md"
{
  echo '# XIndex HITM-Risk Policy Screening'
  echo
  echo '- Workload: YCSB-A'
  echo '- Execution: one complete 400M-operation trace per row'
  echo "- Local/CXL pairs per policy: ${REPEATS_LABEL}"
  echo '- Memory protection: MemoryMax=64G, MemorySwapMax=0'
  echo
  echo '| Policy | Static seeds | Local | CXL | Delta | CXL resident | Max RSS | Safety |'
  echo '|---|---|---:|---:|---:|---:|---:|---|'
  awk -F, 'NR > 1 {
    printf "| %s | %s | %.3fM op/s | %.3fM op/s | %+.2f%% | %.3fGiB | %.3fGiB | %s; fallback=%d, swap=%d |\n", \
      $1, $2, $3 / 1000000, $4 / 1000000, $5, $6, $7, $10, $8, $9
  }' "${COMPARISON_CSV}"
} >"${COMPARISON_MD}"

echo "[screen] complete"
echo "[screen] result root: ${RESULT_ROOT}"
echo "[screen] comparison: ${COMPARISON_MD}"
