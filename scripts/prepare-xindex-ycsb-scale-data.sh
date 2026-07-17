#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${XINDEX_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"
YCSB_TYPES="${YCSB_TYPES:-${YCSB_TYPE:-a}}"
LOAD_RECORDS="${XINDEX_SCALE_LOAD_RECORDS:-100000}"
TX_OPS="${XINDEX_SCALE_TX_OPS:-400000}"
OUT_DIR="${XINDEX_SCALE_DATA_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_scale_${LOAD_RECORDS}_${TX_OPS}}"

usage() {
  cat <<EOF
usage: $0

Creates scaled XIndex/YCSB trace files with the canonical names expected by
scripts/run-generic-placement-experiment.sh.

Environment:
  XINDEX_DATA_DIR            full trace dir, default benchmark/xindex/YCSB/xindex_dat
  XINDEX_SCALE_DATA_DIR      output dir, default build/arbiter-bench/xindex/ycsb_scale_<load>_<tx>
  YCSB_TYPES                 workload list, default "\${YCSB_TYPE:-a}"
  XINDEX_SCALE_LOAD_RECORDS  load INSERT records, default 100000
  XINDEX_SCALE_TX_OPS        transaction ops, default 400000
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    echo "${name} must be a positive integer: ${value}" >&2
    exit 1
  fi
}

restore_data_if_available() {
  if [[ -x "${ROOT_DIR}/scripts/restore-xindex-ycsb-data.sh" ]]; then
    XINDEX_DATA_DIR="${DATA_DIR}" "${ROOT_DIR}/scripts/restore-xindex-ycsb-data.sh"
  fi
}

extract_load() {
  local src="$1"
  local out="$2"

  awk -v max="${LOAD_RECORDS}" '
    /^INSERT/ {
      print
      count++
      if (count >= max) {
        exit
      }
    }
  ' "${src}" > "${out}.tmp"
}

extract_tx() {
  local src="$1"
  local out="$2"

  awk -v max="${TX_OPS}" '
    /^(READ|INSERT|UPDATE|REMOVE)/ {
      print
      count++
      if (count >= max) {
        exit
      }
    }
  ' "${src}" > "${out}.tmp"
}

require_positive_integer XINDEX_SCALE_LOAD_RECORDS "${LOAD_RECORDS}"
require_positive_integer XINDEX_SCALE_TX_OPS "${TX_OPS}"

mkdir -p "${OUT_DIR}"

for ycsb_type in ${YCSB_TYPES}; do
  load_src="${DATA_DIR}/xindex_load_ycsb_${ycsb_type}.dat"
  if [[ "${ycsb_type}" != "a" && ! -f "${load_src}" && -f "${DATA_DIR}/xindex_load_ycsb_a.dat" ]]; then
    load_src="${DATA_DIR}/xindex_load_ycsb_a.dat"
  fi
  tx_src="${DATA_DIR}/xindex_transaction_ycsb_${ycsb_type}.dat"

  if [[ ! -f "${load_src}" || ! -f "${tx_src}" ]]; then
    restore_data_if_available
  fi

  if [[ ! -f "${load_src}" ]]; then
    echo "missing XIndex/YCSB load trace: ${load_src}" >&2
    exit 1
  fi

  if [[ ! -f "${tx_src}" ]]; then
    echo "missing XIndex/YCSB transaction trace: ${tx_src}" >&2
    exit 1
  fi

  load_out="${OUT_DIR}/xindex_load_ycsb_${ycsb_type}.dat"
  tx_out="${OUT_DIR}/xindex_transaction_ycsb_${ycsb_type}.dat"

  extract_load "${load_src}" "${load_out}"
  extract_tx "${tx_src}" "${tx_out}"

  load_count="$(wc -l < "${load_out}.tmp")"
  tx_count="$(wc -l < "${tx_out}.tmp")"

  if [[ "${load_count}" -eq 0 ]]; then
    echo "failed to extract load operations from ${load_src}" >&2
    exit 1
  fi

  if [[ "${tx_count}" -eq 0 ]]; then
    echo "failed to extract transaction operations from ${tx_src}" >&2
    exit 1
  fi

  mv "${load_out}.tmp" "${load_out}"
  mv "${tx_out}.tmp" "${tx_out}"

  cat <<EOF
wrote ${load_out} (${load_count} operations)
wrote ${tx_out} (${tx_count} operations)
EOF
done

cat <<EOF
scaled XIndex/YCSB data dir:
  ${OUT_DIR}
EOF
