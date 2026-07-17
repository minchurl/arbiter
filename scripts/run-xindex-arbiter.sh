#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-local}"
ARBITER_BIN="${ARBITER_XINDEX_BIN:-${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_bench-arbiter}"
DEFAULT_NATIVE_BIN="${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_bench-native"
if [[ ! -x "${DEFAULT_NATIVE_BIN}" ]]; then
  DEFAULT_NATIVE_BIN="${ROOT_DIR}/benchmark/xindex/XIndex-H/build/ycsb_bench"
fi
NATIVE_BIN="${NATIVE_XINDEX_BIN:-${DEFAULT_NATIVE_BIN}}"
FG="${XINDEX_FG:-22}"
ITERATION="${XINDEX_ITERATION:-20}"
YCSB_TYPE="${YCSB_TYPE:-a}"
XINDEX_DATA_DIR="${XINDEX_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"
DEFAULT_LOAD_PATH="${XINDEX_DATA_DIR}/xindex_load_ycsb_${YCSB_TYPE}.dat"
if [[ "${YCSB_TYPE}" != "a" && ! -f "${DEFAULT_LOAD_PATH}" && -f "${XINDEX_DATA_DIR}/xindex_load_ycsb_a.dat" ]]; then
  DEFAULT_LOAD_PATH="${XINDEX_DATA_DIR}/xindex_load_ycsb_a.dat"
fi
LOAD_PATH="${YCSB_LOAD_PATH:-${DEFAULT_LOAD_PATH}}"
TX_PATH="${YCSB_TX_PATH:-${XINDEX_DATA_DIR}/xindex_transaction_ycsb_${YCSB_TYPE}.dat}"
MKL_RUNTIME_DIR="${MKL_RUNTIME_DIR:-/opt/intel/oneapi/mkl/2025.3/lib/intel64}"

if [[ -d "${MKL_RUNTIME_DIR}" ]]; then
  export LD_LIBRARY_PATH="${MKL_RUNTIME_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

restore_data_if_available() {
  if [[ -x "${ROOT_DIR}/scripts/restore-xindex-ycsb-data.sh" && -d "${XINDEX_DATA_DIR}/github-parts" ]]; then
    XINDEX_DATA_DIR="${XINDEX_DATA_DIR}" "${ROOT_DIR}/scripts/restore-xindex-ycsb-data.sh"
  fi
}

if [[ ! -f "${LOAD_PATH}" ]]; then
  restore_data_if_available
fi

if [[ ! -f "${TX_PATH}" ]]; then
  restore_data_if_available
fi

if [[ ! -f "${LOAD_PATH}" ]]; then
  echo "missing YCSB load trace: ${LOAD_PATH}" >&2
  echo "try: ./scripts/import-niagara-workloads.sh --mode copy or ./scripts/restore-xindex-ycsb-data.sh" >&2
  exit 1
fi

if [[ ! -f "${TX_PATH}" ]]; then
  echo "missing YCSB transaction trace: ${TX_PATH}" >&2
  echo "try: ./scripts/import-niagara-workloads.sh --mode copy or ./scripts/restore-xindex-ycsb-data.sh" >&2
  exit 1
fi

common_args=(
  --fg "${FG}"
  --iteration "${ITERATION}"
  --ycsb_type "${YCSB_TYPE}"
  --ycsb-load "${LOAD_PATH}"
  --ycsb-tx "${TX_PATH}"
)

case "${MODE}" in
  native)
    if [[ ! -x "${NATIVE_BIN}" ]]; then
      echo "missing native XIndex binary: ${NATIVE_BIN}" >&2
      echo "try: ./scripts/build-xindex-llvm.sh" >&2
      exit 1
    fi
    exec "${NATIVE_BIN}" "${common_args[@]}"
    ;;
  local)
    unset ARBITER_TARGET_NODE
    if [[ ! -x "${ARBITER_BIN}" ]]; then
      echo "missing Arbiter XIndex binary: ${ARBITER_BIN}" >&2
      echo "try: ./scripts/build-xindex-llvm.sh" >&2
      exit 1
    fi
    exec "${ARBITER_BIN}" "${common_args[@]}"
    ;;
  remote)
    if [[ -z "${ARBITER_TARGET_NODE:-}" ]]; then
      echo "ARBITER_TARGET_NODE must be set for remote mode" >&2
      exit 1
    fi
    if [[ ! -x "${ARBITER_BIN}" ]]; then
      echo "missing Arbiter XIndex binary: ${ARBITER_BIN}" >&2
      echo "try: ./scripts/build-xindex-llvm.sh" >&2
      exit 1
    fi
    exec "${ARBITER_BIN}" "${common_args[@]}"
    ;;
  *)
    echo "usage: $0 [native|local|remote]" >&2
    exit 1
    ;;
esac
