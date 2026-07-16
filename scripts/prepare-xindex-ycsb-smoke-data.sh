#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${XINDEX_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"
OUT_DIR="${XINDEX_SMOKE_DATA_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_dat}"
YCSB_TYPE="${YCSB_TYPE:-a}"
LOAD_RECORDS="${XINDEX_SMOKE_LOAD_RECORDS:-10000}"
TX_OPS="${XINDEX_SMOKE_TX_OPS:-50000}"

LOAD_SRC="${YCSB_LOAD_PATH:-${DATA_DIR}/xindex_load_ycsb_${YCSB_TYPE}.dat}"
if [[ "${YCSB_TYPE}" != "a" && ! -f "${LOAD_SRC}" && -f "${DATA_DIR}/xindex_load_ycsb_a.dat" ]]; then
  LOAD_SRC="${DATA_DIR}/xindex_load_ycsb_a.dat"
fi
TX_SRC="${YCSB_TX_PATH:-${DATA_DIR}/xindex_transaction_ycsb_${YCSB_TYPE}.dat}"

if [[ ! -f "${LOAD_SRC}" || ! -f "${TX_SRC}" ]]; then
  if [[ -x "${ROOT_DIR}/scripts/restore-xindex-ycsb-data.sh" ]]; then
    "${ROOT_DIR}/scripts/restore-xindex-ycsb-data.sh"
  fi
fi

if [[ ! -f "${LOAD_SRC}" ]]; then
  echo "missing XIndex/YCSB load trace: ${LOAD_SRC}" >&2
  exit 1
fi

if [[ ! -f "${TX_SRC}" ]]; then
  echo "missing XIndex/YCSB transaction trace: ${TX_SRC}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

LOAD_OUT="${OUT_DIR}/xindex_load_ycsb_${YCSB_TYPE}.small.dat"
TX_OUT="${OUT_DIR}/xindex_transaction_ycsb_${YCSB_TYPE}.small.dat"

awk -v max="${LOAD_RECORDS}" '
  /^INSERT/ {
    print
    count++
    if (count >= max) {
      exit
    }
  }
' "${LOAD_SRC}" > "${LOAD_OUT}.tmp"

awk -v max="${TX_OPS}" '
  /^(READ|INSERT|UPDATE|REMOVE)/ {
    print
    count++
    if (count >= max) {
      exit
    }
  }
' "${TX_SRC}" > "${TX_OUT}.tmp"

load_count="$(wc -l < "${LOAD_OUT}.tmp")"
tx_count="$(wc -l < "${TX_OUT}.tmp")"

if [[ "${load_count}" -eq 0 ]]; then
  echo "failed to extract load operations from ${LOAD_SRC}" >&2
  exit 1
fi

if [[ "${tx_count}" -eq 0 ]]; then
  echo "failed to extract transaction operations from ${TX_SRC}" >&2
  exit 1
fi

mv "${LOAD_OUT}.tmp" "${LOAD_OUT}"
mv "${TX_OUT}.tmp" "${TX_OUT}"

cat <<EOF
wrote ${LOAD_OUT} (${load_count} operations)
wrote ${TX_OUT} (${tx_count} operations)
EOF
