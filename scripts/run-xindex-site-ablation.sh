#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=run
QUICK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE=check
      ;;
    --quick)
      QUICK=1
      ;;
    -h|--help)
      cat <<'EOF'
usage: scripts/run-xindex-site-ablation.sh [--check] [--quick]

Compares four XIndex/YCSB-A policies with complete 400M-operation one-pass
traces:
  1. site 68 only
  2. sites 68+71
  3. site 71 only
  4. raw-046 (runtime-active sites 68+71+74)

The default is four Local/CXL pairs per policy. --quick runs one pair per
policy. --check validates all inputs without building or running a benchmark.

Common overrides:
  RESULT_ROOT          parent result directory
  REPEATS              Local/CXL pairs per policy, default 4
  BUILD_BENCHMARKS     rebuild each policy binary, default 1
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

RESULT_ROOT="${RESULT_ROOT:-${ROOT_DIR}/build/arbiter-bench/xindex-site-ablation-$(date +%Y%m%d-%H%M%S)}"
if [[ "${RESULT_ROOT}" != /* ]]; then
  RESULT_ROOT="${ROOT_DIR}/${RESULT_ROOT}"
fi

REPLAY_REPEATS="${REPEATS:-4}"
REBUILD="${BUILD_BENCHMARKS:-1}"
if [[ ! "${REPLAY_REPEATS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "REPEATS must be a positive integer: ${REPLAY_REPEATS}" >&2
  exit 1
fi
if [[ "${REBUILD}" != "0" && "${REBUILD}" != "1" ]]; then
  echo "BUILD_BENCHMARKS must be 0 or 1: ${REBUILD}" >&2
  exit 1
fi

POLICY_NAMES=(
  site68-only
  site68-71
  site71-only
  raw-046
)
POLICY_SITES=(
  68
  68+71
  71
  68+71+74
)
POLICY_CONFIGS=(
  configs/hitm-seed/xindex-site68-buffer-ablation.config
  configs/hitm-seed/xindex-site68-71-ablation.config
  configs/hitm-seed/xindex-site71-leaf-ablation.config
  configs/hitm-seed/candidates/raw-046.config
)

for config in "${POLICY_CONFIGS[@]}"; do
  if [[ ! -s "${ROOT_DIR}/${config}" ]]; then
    echo "missing policy config: ${ROOT_DIR}/${config}" >&2
    exit 1
  fi
done

replay_args=()
if [[ "${QUICK}" == "1" ]]; then
  replay_args+=(--quick)
fi

if [[ "${MODE}" == "check" ]]; then
  for index in "${!POLICY_NAMES[@]}"; do
    policy="${POLICY_NAMES[index]}"
    echo "[check] ${policy}: ${POLICY_CONFIGS[index]}"
    env \
      ARBITER_HITM_SEED_CONFIG="${POLICY_CONFIGS[index]}" \
      HITM_SEED_BUILD_DIR="${RESULT_ROOT}/builds/${policy}" \
      RESULT_DIR="${RESULT_ROOT}/runs/${policy}" \
      REPEATS="${REPLAY_REPEATS}" \
      BUILD_BENCHMARKS=0 \
      "${ROOT_DIR}/scripts/run-xindex-hitm-seed-replay.sh" --check "${replay_args[@]}"
  done
  echo "check-only mode: no result directory, build, or benchmark was started"
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
  echo "repeats=${REPLAY_REPEATS}"
  echo "quick=${QUICK}"
  echo "build_benchmarks=${REBUILD}"
  echo "execution_mode=one complete 400M-operation trace per row"
  for index in "${!POLICY_NAMES[@]}"; do
    echo "policy_${index}=${POLICY_NAMES[index]}:${POLICY_CONFIGS[index]}:${POLICY_SITES[index]}"
  done
} >"${RESULT_ROOT}/ablation-manifest.txt"

for index in "${!POLICY_NAMES[@]}"; do
  policy="${POLICY_NAMES[index]}"
  config="${POLICY_CONFIGS[index]}"
  echo "[ablation] starting ${policy} (${config})"
  env \
    ARBITER_HITM_SEED_CONFIG="${config}" \
    HITM_SEED_BUILD_DIR="${RESULT_ROOT}/builds/${policy}" \
    RESULT_DIR="${RESULT_ROOT}/runs/${policy}" \
    REPEATS="${REPLAY_REPEATS}" \
    BUILD_BENCHMARKS="${REBUILD}" \
    "${ROOT_DIR}/scripts/run-xindex-hitm-seed-replay.sh" "${replay_args[@]}"
  echo "[ablation] completed ${policy}"
done

COMPARISON_CSV="${RESULT_ROOT}/comparison.csv"
printf '%s\n' \
  'policy,sites,successful_rows,local_mean_ops,cxl_mean_ops,mean_paired_delta_pct,cxl_resident_gib,result_dir' \
  >"${COMPARISON_CSV}"

for index in "${!POLICY_NAMES[@]}"; do
  policy="${POLICY_NAMES[index]}"
  sites="${POLICY_SITES[index]}"
  run_dir="${RESULT_ROOT}/runs/${policy}"
  awk -F, -v policy="${policy}" -v sites="${sites}" -v run_dir="${run_dir}" '
    NR > 1 && $20 == "ok" {
      ok_rows++
      key = $2 SUBSEP $4
      if ($3 == "hitm-seed-local") {
        local[key] = $14
        local_sum += $14
        local_count++
      } else if ($3 == "hitm-seed-target") {
        target[key] = $14
        target_sum += $14
        target_count++
        resident_sum += $31
        resident_count++
      }
    }
    END {
      pair_count = 0
      delta_sum = 0
      for (key in local) {
        if (local[key] > 0 && target[key] > 0) {
          delta_sum += (target[key] / local[key] - 1) * 100
          pair_count++
        }
      }
      printf "%s,%s,%d,%.6f,%.6f,%.6f,%.6f,%s\n", \
        policy, sites, ok_rows, \
        (local_count ? local_sum / local_count : 0), \
        (target_count ? target_sum / target_count : 0), \
        (pair_count ? delta_sum / pair_count : 0), \
        (resident_count ? resident_sum / resident_count / 1073741824 : 0), \
        run_dir
    }
  ' "${run_dir}/runs.csv" >>"${COMPARISON_CSV}"
done

COMPARISON_MD="${RESULT_ROOT}/comparison.md"
{
  echo '# XIndex Site-Ablation Comparison'
  echo
  echo '- Workload: YCSB-A'
  echo '- Execution: one complete 400M-operation trace per row'
  if [[ "${QUICK}" == "1" ]]; then
    echo '- Repeats: one Local/CXL pair per policy (--quick)'
  else
    echo "- Repeats: ${REPLAY_REPEATS} Local/CXL pairs per policy"
  fi
  echo '- Comparison contract: same rewritten binary and arena allocator within each policy; only arena NUMA placement changes'
  echo
  echo '| Policy | Sites | Successful rows | Local | CXL | Mean paired delta | CXL resident |'
  echo '|---|---|---:|---:|---:|---:|---:|'
  awk -F, 'NR > 1 {
    printf "| %s | %s | %d | %.3fM op/s | %.3fM op/s | %+.2f%% | %.3fGiB |\n", \
      $1, $2, $3, $4 / 1000000, $5 / 1000000, $6, $7
  }' "${COMPARISON_CSV}"
  echo
  echo 'Each policy result directory contains its own manifest, compiler selection report, row logs, placement checks, and interpretation.'
} >"${COMPARISON_MD}"

echo "[ablation] complete"
echo "[ablation] result root: ${RESULT_ROOT}"
echo "[ablation] comparison: ${COMPARISON_MD}"
