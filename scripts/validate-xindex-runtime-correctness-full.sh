#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE=run
REPEATS="${XINDEX_CORRECTNESS_FULL_REPEATS:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE=check
      ;;
    --four-pairs)
      REPEATS=4
      ;;
    -h|--help)
      cat <<'EOF'
usage: scripts/validate-xindex-runtime-correctness-full.sh [--check] [--four-pairs]

Runs a fail-closed XIndex correctness confirmation with the complete 100M-record
load and 400M-transaction trace. Defaults to A and the Site 68+71 ablation.
YCSB_TYPE=f selects read-modify-write; ARBITER_HITM_SEED_CONFIG selects a policy.
RUN_NATIVE=1 includes a native baseline. The default is one Local/CXL pair;
--four-pairs runs the alternating four-pair confirmation.

Run scripts/validate-xindex-runtime-correctness.sh first to pass the ABI,
arena-boundary, and short native/Local/CXL gates.
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

if [[ ! "${REPEATS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "XINDEX_CORRECTNESS_FULL_REPEATS must be a positive integer" >&2
  exit 1
fi

CONFIG="${ARBITER_HITM_SEED_CONFIG:-${ROOT_DIR}/configs/hitm-seed/xindex-site68-71-ablation.config}"
RESULT_DIR="${XINDEX_CORRECTNESS_FULL_RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-runtime-correctness-full-$(date +%Y%m%d-%H%M%S)}"
BUILD_DIR="${XINDEX_CORRECTNESS_FULL_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-runtime-correctness-full-build}"
REBUILD="${BUILD_BENCHMARKS:-1}"
RUN_NATIVE_VALUE="${RUN_NATIVE:-0}"
if [[ "${RUN_NATIVE_VALUE}" != "0" && "${RUN_NATIVE_VALUE}" != "1" ]]; then
  echo "RUN_NATIVE must be 0 or 1" >&2
  exit 1
fi

replay_args=()
if [[ "${MODE}" == "check" ]]; then
  replay_args+=(--check)
fi
if [[ "${REPEATS}" == "1" ]]; then
  replay_args+=(--quick)
fi

env \
  ARBITER_HITM_SEED_CONFIG="${CONFIG}" \
  RESULT_DIR="${RESULT_DIR}" \
  HITM_SEED_BUILD_DIR="${BUILD_DIR}" \
  BUILD_BENCHMARKS="${REBUILD}" \
  RUN_NATIVE="${RUN_NATIVE_VALUE}" \
  REPEATS="${REPEATS}" \
  XINDEX_VALIDATE=1 \
  XINDEX_REQUIRE_ALL_OPERATIONS_SUCCESS=1 \
  XINDEX_VALIDATION_KEYS="${XINDEX_VALIDATION_KEYS:-4096}" \
  "${ROOT_DIR}/scripts/run-xindex-hitm-seed-replay.sh" "${replay_args[@]}"

if [[ "${MODE}" == "check" ]]; then
  exit 0
fi

expected_rows=$((REPEATS * (2 + RUN_NATIVE_VALUE)))
actual_rows="$(awk -F, 'NR > 1 {count++} END {print count + 0}' "${RESULT_DIR}/runs.csv")"
ok_rows="$(awk -F, 'NR > 1 && $20 == "ok" {count++} END {print count + 0}' "${RESULT_DIR}/runs.csv")"
safety_rows="$(awk -F, 'NR > 1 && $17 == 0 && $20 == "ok" &&
                       ($3 == "native" || ($29 == 0 && $32 == $22 && $33 == 0)) {count++}
                         END {print count + 0}' "${RESULT_DIR}/runs.csv")"
if [[ "${actual_rows}" -ne "${expected_rows}" ||
      "${ok_rows}" -ne "${expected_rows}" ||
      "${safety_rows}" -ne "${expected_rows}" ]]; then
  echo "full validation row failure: expected=${expected_rows} actual=${actual_rows} ok=${ok_rows} safe=${safety_rows}" >&2
  exit 1
fi

operation_rows="$(grep -l \
  'xindex-operation-validation attempted=400000000 successful=400000000 failed=0' \
  "${RESULT_DIR}"/logs/*.log | wc -l)"
grep -h '^xindex-operation-validation ' "${RESULT_DIR}"/logs/*.log \
  >"${RESULT_DIR}/validation-operations.txt"
if [[ "$(sort -u "${RESULT_DIR}/validation-operations.txt" | wc -l)" -ne 1 ]]; then
  echo "operation outcomes differ across placements" >&2
  exit 1
fi
if [[ "${YCSB_TYPE:-a}" == "f" ]]; then
  awk '
    {
      delete v
      for (i = 2; i <= NF; ++i) {split($i, kv, "="); v[kv[1]] = kv[2]}
      if (v["rmw_attempted"] <= 0 || v["rmw_successful"] != v["rmw_attempted"] ||
          v["rmw_read_successful"] != v["rmw_attempted"] ||
          v["rmw_update_successful"] != v["rmw_attempted"] ||
          v["get_calls"] != v["read_attempted"] + v["rmw_attempted"] ||
          v["put_calls"] != v["rmw_attempted"] ||
          v["api_calls"] != v["attempted"] + v["rmw_attempted"]) exit 1
    }' "${RESULT_DIR}/validation-operations.txt"
fi
digest_rows="$(grep -h 'xindex-state-validation ' "${RESULT_DIR}"/logs/*.log |
  sed -n 's/.* sampled_keys=4096 successful_reads=4096 failed_reads=0 digest=\([^ ]*\).*/\1/p' |
  tee "${RESULT_DIR}/validation-digests.txt" | wc -l)"
unique_digests="$(sort -u "${RESULT_DIR}/validation-digests.txt" | wc -l)"
if [[ "${operation_rows}" -ne "${expected_rows}" ||
      "${digest_rows}" -ne "${expected_rows}" ||
      "${unique_digests}" -ne 1 ]]; then
  echo "full validation correctness mismatch: operations=${operation_rows} digests=${digest_rows} unique_digests=${unique_digests}" >&2
  exit 1
fi

digest="$(head -1 "${RESULT_DIR}/validation-digests.txt")"
echo "[full-validation] PASS rows=${expected_rows} digest=${digest} result_dir=${RESULT_DIR}"
