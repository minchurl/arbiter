#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_DIR="${RESULT_DIR:-${ROOT_DIR}/build/arbiter-bench/generic-placement-experiment}"
REPEATS="${REPEATS:-3}"
CPU_NODE="${ARBITER_CPU_NODE:-0}"
MEM_NODE="${ARBITER_MEM_NODE:-0}"
TARGET_NODE="${ARBITER_TARGET_NODE:-1}"
RUN_GUPS="${RUN_GUPS:-1}"
RUN_XINDEX="${RUN_XINDEX:-1}"
BUILD_BENCHMARKS="${BUILD_BENCHMARKS:-1}"
XINDEX_WORKLOADS="${XINDEX_WORKLOADS:-a b}"
XINDEX_FG="${XINDEX_FG:-22}"
XINDEX_ITERATION="${XINDEX_ITERATION:-20}"
GUPS_ARGS="${GUPS_ARGS:-16 2000000000 35 8 32 90}"
GUPS_TARGET="${GUPS_TARGET:-gups}"

XINDEX_ALL_DIR="${XINDEX_ALL_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-all}"
XINDEX_GENERIC_DIR="${XINDEX_GENERIC_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-generic}"
GUPS_BUILD_DIR="${GUPS_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/gups}"
XINDEX_DATA_DIR="${XINDEX_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"

MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR:-/opt/intel/oneapi/mkl/2025.3/lib/intel64}"
if [[ -d "${MKL_RUNTIME_DIR}" ]]; then
  export LD_LIBRARY_PATH="${MKL_RUNTIME_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

usage() {
  cat <<EOF
usage: $0

Runs the overnight generic placement experiment.

Useful environment:
  RESULT_DIR        default: build/arbiter-bench/generic-placement-experiment
  REPEATS           default: 3
  RUN_GUPS          default: 1
  RUN_XINDEX        default: 1
  BUILD_BENCHMARKS  default: 1
  XINDEX_WORKLOADS  default: "a b"
  XINDEX_FG         default: 22
  XINDEX_ITERATION  default: 20
  GUPS_ARGS         default: "16 2000000000 35 8 32 90"
  ARBITER_CPU_NODE  default: 0
  ARBITER_MEM_NODE  default: 0
  ARBITER_TARGET_NODE default: 1
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "${RESULT_DIR}/logs"

CSV="${RESULT_DIR}/runs.csv"
if [[ ! -f "${CSV}" ]]; then
  printf 'benchmark,workload,config,repeat,mode,binary,target_node,cpu_node,mem_node,threads,iteration,args,time_sec,throughput,metric,log,time_log,status\n' > "${CSV}"
fi

already_recorded() {
  local benchmark="$1"
  local workload="$2"
  local config="$3"
  local repeat="$4"

  awk -F, \
    -v benchmark="${benchmark}" \
    -v workload="${workload}" \
    -v config="${config}" \
    -v repeat="${repeat}" \
    'NR > 1 && $1 == benchmark && $2 == workload && $3 == config && $4 == repeat && $18 == "ok" {found = 1} END {exit !found}' \
    "${CSV}"
}

append_csv() {
  local benchmark="$1"
  local workload="$2"
  local config="$3"
  local repeat="$4"
  local mode="$5"
  local binary="$6"
  local threads="$7"
  local iteration="$8"
  local args="$9"
  local time_sec="${10}"
  local throughput="${11}"
  local metric="${12}"
  local log="${13}"
  local time_log="${14}"
  local status="${15}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,"%s",%s,%s,%s,%s,%s,%s\n' \
    "${benchmark}" "${workload}" "${config}" "${repeat}" "${mode}" "${binary}" \
    "${TARGET_NODE}" "${CPU_NODE}" "${MEM_NODE}" "${threads}" "${iteration}" "${args}" \
    "${time_sec}" "${throughput}" "${metric}" "${log}" "${time_log}" "${status}" >> "${CSV}"
}

build_benchmarks() {
  if [[ "${BUILD_BENCHMARKS}" != "1" ]]; then
    return 0
  fi

  echo "==> Build GUPS all-select benchmark"
  make -C "${ROOT_DIR}/benchmark/gups" "${GUPS_TARGET}"
  ARBITER_BENCH_BUILD_DIR="${GUPS_BUILD_DIR}" "${ROOT_DIR}/scripts/build-gups-llvm.sh" "${GUPS_TARGET}"

  echo "==> Build XIndex all-select benchmark"
  ARBITER_BENCH_BUILD_DIR="${XINDEX_ALL_DIR}" \
    ARBITER_XINDEX_EXPERIMENT=all \
    "${ROOT_DIR}/scripts/build-xindex-llvm.sh"

  echo "==> Build XIndex generic shared-mutable benchmark"
  ARBITER_BENCH_BUILD_DIR="${XINDEX_GENERIC_DIR}" \
    ARBITER_XINDEX_EXPERIMENT=shared-mutable \
    ARBITER_BUILD_XINDEX_NATIVE=0 \
    "${ROOT_DIR}/scripts/build-xindex-llvm.sh"
}

run_gups_one() {
  local config="$1"
  local repeat="$2"
  local mode="$3"
  local binary="$4"
  local log="${RESULT_DIR}/logs/gups_${config}_r${repeat}.log"
  local time_log="${RESULT_DIR}/logs/gups_${config}_r${repeat}.time"

  if already_recorded "gups" "default" "${config}" "${repeat}"; then
    echo "[skip] gups config=${config} repeat=${repeat}"
    return 0
  fi

  echo "[run] gups config=${config} repeat=${repeat}"

  local -a env_args=(
    "GUPS_TARGET=${GUPS_TARGET}"
    "GUPS_ARGS=${GUPS_ARGS}"
  )
  if [[ "${mode}" == "remote" ]]; then
    env_args+=("ARBITER_TARGET_NODE=${TARGET_NODE}")
  fi
  if [[ -n "${binary}" ]]; then
    if [[ "${mode}" == "native" ]]; then
      env_args+=("NATIVE_GUPS_BIN=${binary}")
    else
      env_args+=("ARBITER_GUPS_BIN=${binary}")
    fi
  fi

  set +e
  /usr/bin/time -v -o "${time_log}" \
    numactl --cpunodebind="${CPU_NODE}" --membind="${MEM_NODE}" \
    env "${env_args[@]}" \
    "${ROOT_DIR}/scripts/run-gups-arbiter.sh" "${mode}" \
    >"${log}" 2>&1
  local rc=$?
  set -e

  local time_sec throughput status
  status="ok"
  if [[ "${rc}" -ne 0 ]]; then
    status="failed:${rc}"
  fi
  time_sec="$(awk '/Elapsed time:/ {v=$3} END {print v}' "${log}")"
  throughput="$(awk '/GUPS =/ {v=$3} END {print v}' "${log}")"
  if [[ "${status}" == "ok" && ( -z "${time_sec}" || -z "${throughput}" ) ]]; then
    status="parse-failed"
  fi

  append_csv "gups" "default" "${config}" "${repeat}" "${mode}" "${binary}" \
    "$(awk '{print $1}' <<<"${GUPS_ARGS}")" "" "${GUPS_ARGS}" \
    "${time_sec}" "${throughput}" "GUPS" "${log}" "${time_log}" "${status}"

  if [[ "${status}" != "ok" ]]; then
    echo "[fail] gups config=${config} repeat=${repeat} status=${status}"
  else
    echo "[done] gups config=${config} repeat=${repeat} time=${time_sec} gups=${throughput}"
  fi
}

run_xindex_one() {
  local workload="$1"
  local config="$2"
  local repeat="$3"
  local mode="$4"
  local binary="$5"
  local log="${RESULT_DIR}/logs/xindex_${workload}_${config}_r${repeat}.log"
  local time_log="${RESULT_DIR}/logs/xindex_${workload}_${config}_r${repeat}.time"
  local load_path="${XINDEX_DATA_DIR}/xindex_load_ycsb_${workload}.dat"
  local tx_path="${XINDEX_DATA_DIR}/xindex_transaction_ycsb_${workload}.dat"

  if [[ "${workload}" != "a" && ! -f "${load_path}" ]]; then
    load_path="${XINDEX_DATA_DIR}/xindex_load_ycsb_a.dat"
  fi

  if already_recorded "xindex" "${workload}" "${config}" "${repeat}"; then
    echo "[skip] xindex workload=${workload} config=${config} repeat=${repeat}"
    return 0
  fi

  echo "[run] xindex workload=${workload} config=${config} repeat=${repeat}"

  local -a env_args=(
    "YCSB_TYPE=${workload}"
    "XINDEX_FG=${XINDEX_FG}"
    "XINDEX_ITERATION=${XINDEX_ITERATION}"
    "YCSB_LOAD_PATH=${load_path}"
    "YCSB_TX_PATH=${tx_path}"
    "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
  )
  if [[ -n "${binary}" ]]; then
    if [[ "${mode}" == "native" ]]; then
      env_args+=("NATIVE_XINDEX_BIN=${binary}")
    else
      env_args+=("ARBITER_XINDEX_BIN=${binary}")
    fi
  fi
  if [[ "${mode}" == "remote" ]]; then
    env_args+=("ARBITER_TARGET_NODE=${TARGET_NODE}")
  fi

  set +e
  /usr/bin/time -v -o "${time_log}" \
    numactl --cpunodebind="${CPU_NODE}" --membind="${MEM_NODE}" \
    env "${env_args[@]}" \
    "${ROOT_DIR}/scripts/run-xindex-arbiter.sh" "${mode}" \
    >"${log}" 2>&1
  local rc=$?
  set -e

  local time_sec throughput status
  status="ok"
  if [[ "${rc}" -ne 0 ]]; then
    status="failed:${rc}"
  fi
  time_sec="$(awk -F': ' '/\[ycsb\] Time\(sec\)/ {v=$NF} END {print v}' "${log}")"
  throughput="$(awk -F': ' '/\[ycsb\] Throughput\(op\/s\)/ {v=$NF} END {print v}' "${log}")"
  if [[ "${status}" == "ok" && ( -z "${time_sec}" || -z "${throughput}" ) ]]; then
    status="parse-failed"
  fi

  append_csv "xindex" "${workload}" "${config}" "${repeat}" "${mode}" "${binary}" \
    "${XINDEX_FG}" "${XINDEX_ITERATION}" "" \
    "${time_sec}" "${throughput}" "op/s" "${log}" "${time_log}" "${status}"

  if [[ "${status}" != "ok" ]]; then
    echo "[fail] xindex workload=${workload} config=${config} repeat=${repeat} status=${status}"
  else
    echo "[done] xindex workload=${workload} config=${config} repeat=${repeat} time=${time_sec} throughput=${throughput}"
  fi
}

build_benchmarks

if [[ "${RUN_GUPS}" == "1" ]]; then
  for repeat in $(seq 1 "${REPEATS}"); do
    run_gups_one "native" "${repeat}" "native" "${ROOT_DIR}/benchmark/gups/${GUPS_TARGET}"
    run_gups_one "all-local" "${repeat}" "local" "${GUPS_BUILD_DIR}/${GUPS_TARGET}-arbiter"
    run_gups_one "all-remote" "${repeat}" "remote" "${GUPS_BUILD_DIR}/${GUPS_TARGET}-arbiter"
  done
fi

if [[ "${RUN_XINDEX}" == "1" ]]; then
  for workload in ${XINDEX_WORKLOADS}; do
    for repeat in $(seq 1 "${REPEATS}"); do
      run_xindex_one "${workload}" "native" "${repeat}" "native" "${XINDEX_ALL_DIR}/ycsb_bench-native"
      run_xindex_one "${workload}" "all-local" "${repeat}" "local" "${XINDEX_ALL_DIR}/ycsb_bench-arbiter"
      run_xindex_one "${workload}" "generic-local" "${repeat}" "local" "${XINDEX_GENERIC_DIR}/ycsb_bench-arbiter"
      run_xindex_one "${workload}" "all-remote" "${repeat}" "remote" "${XINDEX_ALL_DIR}/ycsb_bench-arbiter"
      run_xindex_one "${workload}" "generic-remote" "${repeat}" "remote" "${XINDEX_GENERIC_DIR}/ycsb_bench-arbiter"
    done
  done
fi

"${ROOT_DIR}/scripts/summarize-generic-placement-experiment.sh" "${RESULT_DIR}"

cat <<EOF

Experiment complete.
Results:
  ${RESULT_DIR}/runs.csv
  ${RESULT_DIR}/summary.csv
  ${RESULT_DIR}/summary.md
EOF
