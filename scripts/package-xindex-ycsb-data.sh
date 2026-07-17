#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${XINDEX_DATA_DIR:-${ROOT_DIR}/benchmark/xindex/YCSB/xindex_dat}"
PARTS_DIR="${XINDEX_DATA_PARTS_DIR:-${DATA_DIR}/github-parts}"
CHUNK_SIZE="${XINDEX_DATA_CHUNK_SIZE:-1900M}"
ZSTD_LEVEL="${XINDEX_DATA_ZSTD_LEVEL:-3}"
REQUIRE_GIT_LFS="${REQUIRE_GIT_LFS:-1}"
DATA_FILES=(
  xindex_load_ycsb_a.dat
  xindex_transaction_ycsb_a.dat
  xindex_transaction_ycsb_b.dat
)

if [[ "${REQUIRE_GIT_LFS}" == "1" ]] && ! git lfs version >/dev/null 2>&1; then
  cat >&2 <<EOF
git-lfs is required before packaging these chunks for GitHub.

Install git-lfs, run 'git lfs install', then retry. The generated chunks are
larger than regular GitHub's 100MiB object limit and must be tracked by LFS or
uploaded as release assets.
EOF
  exit 1
fi

mkdir -p "${PARTS_DIR}"

for file in "${DATA_FILES[@]}"; do
  src="${DATA_DIR}/${file}"
  if [[ ! -f "${src}" ]]; then
    echo "missing ${src}; run scripts/import-niagara-workloads.sh first" >&2
    exit 1
  fi
done

(
  cd "${DATA_DIR}"
  sha256sum "${DATA_FILES[@]}"
) > "${PARTS_DIR}/MANIFEST.sha256"

for file in "${DATA_FILES[@]}"; do
  src="${DATA_DIR}/${file}"
  prefix="${PARTS_DIR}/${file}.zst.part-"

  rm -f "${prefix}"*
  echo "packaging ${src}"
  zstd -T0 "-${ZSTD_LEVEL}" -c "${src}" | split -b "${CHUNK_SIZE}" -d -a 4 - "${prefix}"
done

cat <<EOF

Wrote chunked data to:
  ${PARTS_DIR}

The default chunk size is ${CHUNK_SIZE}, below GitHub Free/Pro's 2GB LFS
per-file limit. Commit .gitattributes and these parts with git-lfs enabled, or
upload the parts as GitHub release assets.
EOF
