#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLVM_VERSION="${LLVM_VERSION:-18}"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm${LLVM_VERSION}}"
GUPS_DIR="${GUPS_OUT_DIR:-${BUILD_DIR}/benchmarks/gups}"
SYSTEM_BENCH="${GUPS_SYSTEM_BENCH:-${GUPS_DIR}/gups-system}"
ARBITER_BENCH="${GUPS_ARBITER_BENCH:-${GUPS_DIR}/gups-arbiter}"

TABLE_MIB="${TABLE_MIB:-256}"
UPDATES="${UPDATES:-}"
HOT_REGION_PERCENT="${HOT_REGION_PERCENT:-100}"
HOT_ACCESS_PERCENT="${HOT_ACCESS_PERCENT:-100}"
REPEATS="${REPEATS:-1}"
MODES="${MODES:-system arbiter}"

if [[ ! -x "${SYSTEM_BENCH}" || ! -x "${ARBITER_BENCH}" ]]; then
  echo "run_gups_bench: benchmark binaries not found under ${GUPS_DIR}" >&2
  echo "run_gups_bench: build them first with scripts/build_gups_pipeline.sh" >&2
  exit 1
fi

echo "repeat,mode,requested_table_mib,actual_table_mib,table_entries,hot_region_percent,hot_entries,hot_access_percent,updates,elapsed_s,gups,ns_per_update,checksum,arbiter_target_node"

for repeat in $(seq 1 "${REPEATS}"); do
  for mode in ${MODES}; do
    case "${mode}" in
      system)
        bench="${SYSTEM_BENCH}"
        ;;
      arbiter)
        bench="${ARBITER_BENCH}"
        ;;
      *)
        echo "run_gups_bench: unknown mode '${mode}'" >&2
        exit 1
        ;;
    esac

    args=(
      --mode "${mode}"
      --table-mib "${TABLE_MIB}"
      --hot-region-percent "${HOT_REGION_PERCENT}"
      --hot-access-percent "${HOT_ACCESS_PERCENT}"
      --csv
    )
    if [[ -n "${UPDATES}" ]]; then
      args+=(--updates "${UPDATES}")
    fi

    line="$("${bench}" "${args[@]}" "$@")"
    echo "${repeat},${line}"
  done
done
