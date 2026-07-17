#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_ROOT="${NIAGARA_WORKLOADS:-${HOME}/niagara_workloads}"
MODE="copy"

usage() {
  cat <<EOF
usage: $0 [--mode copy|hardlink|symlink]

Imports the full XIndex/YCSB trace files from NIAGARA_WORKLOADS
(default: ~/niagara_workloads) into benchmark/xindex/YCSB/xindex_dat.

copy     duplicates the files into this repository
hardlink links the files without consuming another 46GB on the same filesystem
symlink  links by path for local-only runs
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "${MODE}" in
  copy|hardlink|symlink) ;;
  *)
    echo "unknown mode: ${MODE}" >&2
    usage >&2
    exit 1
    ;;
esac

SRC_DATA_DIR="${SRC_ROOT}/YCSB/xindex_dat"
DST_DATA_DIR="${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat"
DATA_FILES=(
  xindex_load_ycsb_a.dat
  xindex_transaction_ycsb_a.dat
  xindex_transaction_ycsb_b.dat
)

if [[ ! -d "${SRC_DATA_DIR}" ]]; then
  echo "missing source data directory: ${SRC_DATA_DIR}" >&2
  exit 1
fi

mkdir -p "${DST_DATA_DIR}"

import_one() {
  local src="$1"
  local dst="$2"

  if [[ ! -f "${src}" ]]; then
    echo "missing source file: ${src}" >&2
    return 1
  fi

  case "${MODE}" in
    copy)
      cp -p "${src}" "${dst}.tmp"
      mv "${dst}.tmp" "${dst}"
      ;;
    hardlink)
      ln -f "${src}" "${dst}"
      ;;
    symlink)
      ln -sfn "${src}" "${dst}"
      ;;
  esac

  echo "imported ${dst}"
}

for file in "${DATA_FILES[@]}"; do
  import_one "${SRC_DATA_DIR}/${file}" "${DST_DATA_DIR}/${file}"
done

cat <<EOF

Imported XIndex/YCSB traces into:
  ${DST_DATA_DIR}

The raw .dat files are intentionally ignored by git. To prepare a GitHub-safe
chunked copy after installing git-lfs, run:
  ${ROOT_DIR}/scripts/package-xindex-ycsb-data.sh
EOF
