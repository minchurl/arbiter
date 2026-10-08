#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
usage: scripts/summarize-xindex-hitm-seed-result.sh [RESULT_DIR]

Prints a Markdown interpretation of one XIndex HITM-risk seed result.
When RESULT_DIR is omitted, the newest canonical replay under
build/arbiter-bench/ is used.

The report distinguishes:
  - static seeds selected and rewritten by the compiler;
  - runtime-active sites that actually allocated objects in the trace;
  - verified resident memory placement and safety counters.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 1
fi

RESULT_DIR="${1:-}"
if [[ -z "${RESULT_DIR}" ]]; then
  shopt -s nullglob
  candidates=("${ROOT_DIR}"/build/arbiter-bench/xindex-hitm-seed-replay-*)
  shopt -u nullglob
  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}/runs.csv" && \
          ( -z "${RESULT_DIR}" || "${candidate}" > "${RESULT_DIR}" ) ]]; then
      RESULT_DIR="${candidate}"
    fi
  done
  if [[ -z "${RESULT_DIR}" ]]; then
    echo "no canonical replay result found under ${ROOT_DIR}/build/arbiter-bench" >&2
    exit 1
  fi
elif [[ "${RESULT_DIR}" != /* ]]; then
  RESULT_DIR="${ROOT_DIR}/${RESULT_DIR}"
fi

RUNS_CSV="${RESULT_DIR}/runs.csv"
SUMMARY_CSV="${RESULT_DIR}/summary.csv"
SITES_CSV="${RESULT_DIR}/hitm-seed-sites.csv"
POLICY_CONFIG="${RESULT_DIR}/hitm-seed-input.config"
for required in "${RUNS_CSV}" "${SUMMARY_CSV}" "${SITES_CSV}"; do
  if [[ ! -s "${required}" ]]; then
    echo "missing result artifact: ${required}" >&2
    exit 1
  fi
done

SELECTED_COUNT="$(awk -F, 'NR > 1 && $12 == "yes" {count++} END {print count + 0}' "${SITES_CSV}")"
FIRST_ITERATION="$(awk -F, 'NR > 1 {print $11; exit}' "${RUNS_CSV}")"
FIRST_DURATION="$(awk -F, 'NR > 1 {print $30; exit}' "${RUNS_CSV}")"
FIRST_SAMPLE="$(awk -F, 'NR > 1 {print $34; exit}' "${RUNS_CSV}")"
TARGET_INFO="$(awk -F, 'NR > 1 && $5 == "remote" && $20 == "ok" {print $2 "," $4 "," $18; exit}' "${RUNS_CSV}")"
TARGET_WORKLOAD=""
TARGET_REPEAT=""
TARGET_LOG=""
if [[ -n "${TARGET_INFO}" ]]; then
  IFS=, read -r TARGET_WORKLOAD TARGET_REPEAT TARGET_LOG <<< "${TARGET_INFO}"
fi

printf '# XIndex HITM-Risk Seed Result Interpretation\n\n'
printf -- '- Result directory: `%s`\n' "${RESULT_DIR}"
printf -- '- Static seeds selected by the compiler: %s\n' "${SELECTED_COUNT}"
if [[ "${FIRST_DURATION}" == "0" ]]; then
  printf -- '- Execution contract: fixed-operation, %s complete trace pass(es), no duration cutoff\n' \
    "${FIRST_ITERATION}"
else
  printf -- '- Execution contract: %s-second cyclic trace replay, sampled every %s second(s)\n' \
    "${FIRST_DURATION}" "${FIRST_SAMPLE}"
fi
printf -- '- Comparison: the same rewritten binary and arena allocator; only the arena NUMA node changes\n\n'

if [[ -s "${POLICY_CONFIG}" ]]; then
  config_value() {
    local key="$1"
    awk -F= -v key="${key}" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' \
      "${POLICY_CONFIG}"
  }
  MIN_SCORE="$(config_value ARBITER_HITM_MIN_SCORE)"
  SEED_LIMIT="$(config_value ARBITER_HITM_SEED_LIMIT)"
  EXPLICIT_SITE_IDS="$(config_value ARBITER_HITM_SEED_SITE_IDS)"
  SIZE_WEIGHT="$(config_value ARBITER_HITM_WEIGHT_SIZE)"
  REQUIRE_ESCAPE="$(config_value ARBITER_HITM_REQUIRE_ESCAPE)"
  REQUIRE_SYNC="$(config_value ARBITER_HITM_REQUIRE_SYNC)"
  LARGE_THRESHOLD="$(config_value ARBITER_HITM_LARGE_ALLOCATION_THRESHOLD)"
  INCLUDE_DYNAMIC="$(config_value ARBITER_HITM_INCLUDE_DYNAMIC_SIZE)"

  printf '## Selection Policy\n\n'
  printf '| Parameter | Value | Meaning |\n'
  printf '|---|---:|---|\n'
  printf '| Minimum score | %s | selection threshold |\n' "${MIN_SCORE:-unknown}"
  printf '| Seed limit | %s | maximum selected groups/sites after ranking |\n' "${SEED_LIMIT:-unknown}"
  printf '| Explicit site IDs | `%s` | `%s` means score-based automatic selection |\n' \
    "${EXPLICIT_SITE_IDS:-empty}" "${EXPLICIT_SITE_IDS:-empty}"
  printf '| Size weight | %s | score weight for allocation size |\n' "${SIZE_WEIGHT:-unknown}"
  printf '| Require escape / synchronization | %s / %s | both gates must pass |\n' \
    "${REQUIRE_ESCAPE:-unknown}" "${REQUIRE_SYNC:-unknown}"
  printf '| Large-allocation threshold | %sB | size signal threshold |\n' \
    "${LARGE_THRESHOLD:-unknown}"
  printf '| Include dynamic-size sites | %s | disabled in the retained policy |\n\n' \
    "${INCLUDE_DYNAMIC:-unknown}"
fi

printf '## Throughput\n\n'
printf '| Workload | Placement | Successful rows | Mean measured time | Mean throughput | Mean max RSS |\n'
printf '|---|---|---:|---:|---:|---:|\n'
awk -F, 'NR > 1 {
  placement = $3
  sub(/^hitm-seed-/, "", placement)
  printf "| %s | %s | %s | %.3fs | %.3fM op/s | %.3fGiB |\n", \
         $2, placement, $5, $6, $7 / 1000000, $8 / 1048576
}' "${SUMMARY_CSV}"
printf '\n### Complete Local/CXL Pairs\n\n'
printf '| Workload | Repeat | Local | CXL target | CXL vs local |\n'
printf '|---|---:|---:|---:|---:|\n'
awk -F, '
  NR > 1 && $20 == "ok" && ($3 == "hitm-seed-local" || $3 == "hitm-seed-target") {
    key = $2 SUBSEP $4
    if (!(key in seen)) {
      seen[key] = 1
      keys[++key_count] = key
      workload[key] = $2
      repeat[key] = $4
    }
    if ($3 == "hitm-seed-local") local[key] = $14
    if ($3 == "hitm-seed-target") target[key] = $14
  }
  END {
    pair_count = 0
    delta_sum = 0
    for (i = 1; i <= key_count; ++i) {
      key = keys[i]
      if (local[key] > 0 && target[key] > 0) {
        delta = (target[key] / local[key] - 1) * 100
        printf "| %s | %s | %.3fM op/s | %.3fM op/s | %+.2f%% |\n", \
               workload[key], repeat[key], local[key] / 1000000, \
               target[key] / 1000000, delta
        delta_sum += delta
        pair_count++
      }
    }
    if (pair_count == 0)
      print "| - | - | - | - | no complete pair |"
    else
      printf "\nMean of %d paired deltas: **%+.2f%%**\n", pair_count, delta_sum / pair_count
  }
' "${RUNS_CSV}"
printf '\n'

printf '## Static Compiler Selection\n\n'
printf 'These sites were selected from the score and policy parameters and had their allocation calls rewritten. Selection does not mean that a call executes in this workload.\n\n'
printf '| Site | Kind | Function | Source | Object estimate | Score | Group | Selection signals |\n'
printf '|---:|---|---|---|---:|---:|---:|---|\n'
awk -F, -v root="${ROOT_DIR}/" 'NR > 1 && $12 == "yes" {
  source = $4
  sub("^" root, "", source)
  signals = $13
  gsub(/^"|"$/, "", signals)
  gsub(/;/, ", ", signals)
  printf "| %s | %s | `%s` | `%s:%s` | %sB | %s | %s | %s |\n", \
         $1, $2, $3, source, $5, $8, $9, $11, signals
}' "${SITES_CSV}"
printf '\n'

printf '## Runtime-Active CXL Sites\n\n'
if [[ -n "${TARGET_LOG}" && -s "${TARGET_LOG}" ]]; then
  printf 'The following selected sites actually allocated objects in target row `%s/r%s`. Their arena slabs were bound to the CXL target node.\n\n' "${TARGET_WORKLOAD}" "${TARGET_REPEAT}"
  printf '| Site | Function | Object | Allocations | Requested payload | Assigned arena |\n'
  printf '|---:|---|---:|---:|---:|---:|\n'
  awk -F, '
    FNR == NR {
      if (FNR > 1 && $12 == "yes") function_name[$1] = $3
      next
    }
    /^arbiter-arena-site / {
      delete value
      field_count = split($0, tokens, /[[:space:]]+/)
      for (i = 2; i <= field_count; ++i) {
        split(tokens[i], field, "=")
        value[field[1]] = field[2]
      }
      site = value["site"]
      printf "| %s | `%s` | %sB | %s | %.3fGiB | %.3fGiB |\n", \
             site, function_name[site], value["object_bytes"], \
             value["allocations"], value["requested_bytes_total"] / 1073741824, \
             value["assigned_bytes"] / 1073741824
    }
  ' "${SITES_CSV}" "${TARGET_LOG}"

  ACTIVE_SITE_IDS="$(awk '
    /^arbiter-arena-site / {
      for (i = 2; i <= NF; ++i) {
        split($i, field, "=")
        if (field[1] == "site") {
          if (count++) printf ","
          printf "%s", field[2]
        }
      }
    }
    END {print ""}
  ' "${TARGET_LOG}")"
  INACTIVE_SITE_IDS="$(awk -F, -v active="${ACTIVE_SITE_IDS}" '
    BEGIN {
      count = split(active, ids, ",")
      for (i = 1; i <= count; ++i) is_active[ids[i]] = 1
    }
    NR > 1 && $12 == "yes" && !is_active[$1] {
      if (printed++) printf ","
      printf "%s", $1
    }
    END {print ""}
  ' "${SITES_CSV}")"
  printf '\nRuntime-active site IDs: `%s`. Selected but inactive in this trace: `%s`.\n\n' \
    "${ACTIVE_SITE_IDS:-none}" "${INACTIVE_SITE_IDS:-none}"
else
  printf 'No successful CXL target row with a readable log was found.\n\n'
fi

printf '## Placement and Safety Validation\n\n'
printf '| Workload | Repeat | Placement | Status | Requested node | Resident | Majority node | Fallbacks | Swaps |\n'
printf '|---|---:|---|---|---:|---:|---:|---:|---:|\n'
awk -F, 'NR > 1 && ($3 == "hitm-seed-local" || $3 == "hitm-seed-target") {
  placement = $3
  sub(/^hitm-seed-/, "", placement)
  resident = ($31 == "" ? "-" : sprintf("%.3fGiB", $31 / 1073741824))
  printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", \
         $2, $4, placement, $20, $22, resident, \
         ($32 == "" ? "-" : $32), ($29 == "" ? "-" : $29), \
         ($17 == "" ? "-" : $17)
}' "${RUNS_CSV}"
printf '\n`Resident` is the physical memory occupied by the selected-site arena. `Assigned arena` also includes slot padding and slab granularity, so it can exceed requested object payload. A trustworthy placement row should be `ok`, have majority node equal to requested node, and report zero fallbacks and swaps.\n'
