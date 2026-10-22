#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${YCSB_LOAD_PATH:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_a.dat}"
OUT_DIR="${XINDEX_CORRECTNESS_DATA_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex-correctness-data}"
LOAD_RECORDS="${XINDEX_CORRECTNESS_LOAD_RECORDS:-200000}"
TX_OPERATIONS="${XINDEX_CORRECTNESS_TX_OPERATIONS:-1000000}"

if [[ ! -f "${SOURCE}" ]]; then
  echo "missing YCSB-A load trace: ${SOURCE}" >&2
  exit 1
fi
if [[ ! "${LOAD_RECORDS}" =~ ^[1-9][0-9]*$ ||
      ! "${TX_OPERATIONS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "record and operation counts must be positive integers" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"
LOAD_OUT="${OUT_DIR}/xindex_load_ycsb_a.correctness.dat"
TX_OUT="${OUT_DIR}/xindex_transaction_ycsb_a.correctness.dat"

awk -v max="${LOAD_RECORDS}" '
  /^INSERT usertable user/ {
    print
    if (++count >= max)
      exit
  }
' "${SOURCE}" >"${LOAD_OUT}.tmp"

actual_load="$(wc -l <"${LOAD_OUT}.tmp")"
if [[ "${actual_load}" -ne "${LOAD_RECORDS}" ]]; then
  echo "requested ${LOAD_RECORDS} load records, found ${actual_load}" >&2
  exit 1
fi

# Generate a deterministic YCSB-A-shaped stream from the extracted keys.
# This avoids the invalid short-trace pattern where transactions refer to keys
# omitted from a separately truncated load trace.
awk -v max="${TX_OPERATIONS}" '
  /^INSERT usertable user/ {
    key = $3
    sub(/^user/, "", key)
    keys[++count] = key
  }
  END {
    for (i = 0; i < max; ++i) {
      key = keys[(i % count) + 1]
      if ((i % 2) == 0)
        print "READ usertable user" key " [ <all fields>]"
      else
        print "UPDATE usertable user" key " [ field0=validation ]"
    }
  }
' "${LOAD_OUT}.tmp" >"${TX_OUT}.tmp"

mv "${LOAD_OUT}.tmp" "${LOAD_OUT}"
mv "${TX_OUT}.tmp" "${TX_OUT}"

printf 'correctness_load=%s records=%s\n' "${LOAD_OUT}" "${LOAD_RECORDS}"
printf 'correctness_tx=%s operations=%s read_ratio=0.5 update_ratio=0.5\n' \
  "${TX_OUT}" "${TX_OPERATIONS}"
