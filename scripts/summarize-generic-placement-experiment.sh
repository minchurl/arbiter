#!/usr/bin/env bash
set -euo pipefail

RESULT_DIR="${1:-build/arbiter-bench/generic-placement-experiment}"
CSV="${RESULT_DIR}/runs.csv"
SUMMARY_CSV="${RESULT_DIR}/summary.csv"
SUMMARY_MD="${RESULT_DIR}/summary.md"
TMP_CSV="${SUMMARY_CSV}.tmp"

if [[ ! -f "${CSV}" ]]; then
  echo "missing runs.csv: ${CSV}" >&2
  exit 1
fi

awk -F, '
  NR == 1 { next }
  $18 != "ok" { failed[$1 "," $2 "," $3]++; next }
  {
    key = $1 "," $2 "," $3 "," $15
    n[key]++
    time_sum[key] += $13 + 0
    thr_sum[key] += $14 + 0
    if (!(key in time_min) || $13 + 0 < time_min[key]) time_min[key] = $13 + 0
    if (!(key in time_max) || $13 + 0 > time_max[key]) time_max[key] = $13 + 0
    if (!(key in thr_min) || $14 + 0 < thr_min[key]) thr_min[key] = $14 + 0
    if (!(key in thr_max) || $14 + 0 > thr_max[key]) thr_max[key] = $14 + 0
  }
  END {
    print "benchmark,workload,config,metric,repeats,avg_time_sec,min_time_sec,max_time_sec,avg_throughput,min_throughput,max_throughput"
    for (key in n) {
      split(key, parts, ",")
      printf "%s,%s,%s,%s,%d,%.6g,%.6g,%.6g,%.6g,%.6g,%.6g\n",
        parts[1], parts[2], parts[3], parts[4], n[key],
        time_sum[key] / n[key], time_min[key], time_max[key],
        thr_sum[key] / n[key], thr_min[key], thr_max[key]
    }
  }
' "${CSV}" > "${TMP_CSV}"

{
  head -n 1 "${TMP_CSV}"
  tail -n +2 "${TMP_CSV}" | sort
} > "${SUMMARY_CSV}"
rm -f "${TMP_CSV}"

{
  echo "# Generic Placement Experiment Summary"
  echo
  echo "Source CSV: \`${CSV}\`"
  echo
  echo "| Benchmark | Workload | Config | Metric | Repeats | Avg Time (s) | Avg Throughput |"
  echo "|---|---:|---|---|---:|---:|---:|"
  awk -F, 'NR > 1 {
    printf "| %s | %s | %s | %s | %s | %.3f | %.6g |\n", $1, $2, $3, $4, $5, $6, $9
  }' "${SUMMARY_CSV}"
  echo
  echo "## Raw Files"
  echo
  echo "- Runs: \`${CSV}\`"
  echo "- Summary CSV: \`${SUMMARY_CSV}\`"
  echo "- Logs: \`${RESULT_DIR}/logs\`"
  echo
  echo "## Non-OK Runs"
  echo
  if awk -F, 'NR > 1 && $18 != "ok" {found = 1} END {exit !found}' "${CSV}"; then
    echo "| Benchmark | Workload | Config | Repeat | Status | Log |"
    echo "|---|---:|---|---:|---|---|"
    awk -F, 'NR > 1 && $18 != "ok" {
      printf "| %s | %s | %s | %s | %s | `%s` |\n", $1, $2, $3, $4, $18, $16
    }' "${CSV}"
  else
    echo "None."
  fi
} > "${SUMMARY_MD}"

echo "wrote ${SUMMARY_CSV}"
echo "wrote ${SUMMARY_MD}"
