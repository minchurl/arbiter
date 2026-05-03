#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf "Arbiter setup check\n"
printf "repo: %s\n\n" "${ROOT_DIR}"

for tool in cmake ninja clang++ llvm-config mlir-tblgen mlir-opt FileCheck; do
  if command -v "${tool}" >/dev/null 2>&1; then
    printf "found: %s -> %s\n" "${tool}" "$(command -v "${tool}")"
  else
    printf "missing: %s\n" "${tool}"
  fi
done

cat <<EOF

Suggested build:
  cmake -S "${ROOT_DIR}" -B "${ROOT_DIR}/build-ninja" -G Ninja \\
    -DMLIR_DIR="\$(llvm-config --cmakedir | sed 's#/llvm\$#/mlir#')"
  cmake --build "${ROOT_DIR}/build-ninja" --target arbiter-opt arbiter-runtime-smoke

Then try:
  "${ROOT_DIR}/scripts/smoke.sh"
EOF
