#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${XINDEX_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"
PARTS_DIR="${XINDEX_DATA_PARTS_DIR:-${DATA_DIR}/github-parts}"
OVERWRITE="${OVERWRITE:-0}"
DATA_FILES=(
  xindex_load_ycsb_a.dat
  xindex_transaction_ycsb_a.dat
)
if [[ "${1:-}" == "--include-archived-b" && $# == 1 ]]; then
  DATA_FILES+=(xindex_transaction_ycsb_b.dat)
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--include-archived-b]" >&2
  exit 1
fi

mkdir -p "${DATA_DIR}"

for file in "${DATA_FILES[@]}"; do
  dst="${DATA_DIR}/${file}"
  parts=("${PARTS_DIR}/${file}.zst.part-"*)

  if [[ -f "${dst}" && "${OVERWRITE}" != "1" ]]; then
    echo "keeping existing ${dst}"
    continue
  fi

  if [[ ${#parts[@]} -eq 0 ]]; then
    echo "missing parts for ${file} in ${PARTS_DIR}" >&2
    exit 1
  fi

  echo "restoring ${dst}"
  cat "${parts[@]}" | zstd -d -c > "${dst}.tmp"
  mv "${dst}.tmp" "${dst}"
done

if [[ -f "${PARTS_DIR}/MANIFEST.sha256" ]]; then
  (
    cd "${DATA_DIR}"
    for file in "${DATA_FILES[@]}"; do
      checksum="$(awk -v file="${file}" '$2 == file {print}' "${PARTS_DIR}/MANIFEST.sha256")"
      [[ -n "${checksum}" ]] || { echo "missing checksum for ${file}" >&2; exit 1; }
      printf '%s\n' "${checksum}" | sha256sum -c -
    done
  )
fi
