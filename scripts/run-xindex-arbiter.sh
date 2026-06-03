#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-local}"
ARBITER_BIN="${ARBITER_XINDEX_BIN:-${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_bench-arbiter}"
NATIVE_BIN="${NATIVE_XINDEX_BIN:-${ROOT_DIR}/benchmark/xindex/XIndex-H/build/ycsb_bench}"
FG="${XINDEX_FG:-22}"
ITERATION="${XINDEX_ITERATION:-20}"
YCSB_TYPE="${YCSB_TYPE:-a}"
LOAD_PATH="${YCSB_LOAD_PATH:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_${YCSB_TYPE}.dat}"
TX_PATH="${YCSB_TX_PATH:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_${YCSB_TYPE}.dat}"

common_args=(
  --fg "${FG}"
  --iteration "${ITERATION}"
  --ycsb_type "${YCSB_TYPE}"
  --ycsb-load "${LOAD_PATH}"
  --ycsb-tx "${TX_PATH}"
)

case "${MODE}" in
  native)
    exec "${NATIVE_BIN}" "${common_args[@]}"
    ;;
  local)
    unset ARBITER_TARGET_NODE
    exec "${ARBITER_BIN}" "${common_args[@]}"
    ;;
  remote)
    if [[ -z "${ARBITER_TARGET_NODE:-}" ]]; then
      echo "ARBITER_TARGET_NODE must be set for remote mode" >&2
      exit 1
    fi
    exec "${ARBITER_BIN}" "${common_args[@]}"
    ;;
  *)
    echo "usage: $0 [native|local|remote]" >&2
    exit 1
    ;;
esac
