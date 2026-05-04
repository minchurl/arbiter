#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLVM_VERSION="${LLVM_VERSION:-18}"
LLVM_PREFIX="${LLVM_PREFIX:-/usr/lib/llvm-${LLVM_VERSION}}"

find_tool() {
  local tool="$1"

  if [[ -x "${LLVM_PREFIX}/bin/${tool}" ]]; then
    printf "%s" "${LLVM_PREFIX}/bin/${tool}"
    return 0
  fi

  command -v "${tool}-${LLVM_VERSION}" 2>/dev/null || command -v "${tool}"
}

printf "Arbiter setup check\n"
printf "repo: %s\n\n" "${ROOT_DIR}"
printf "LLVM baseline: %s\n" "${LLVM_VERSION}"
printf "LLVM prefix: %s\n\n" "${LLVM_PREFIX}"

for tool in cmake ninja clang clang++ llvm-config mlir-tblgen mlir-opt FileCheck; do
  if path="$(find_tool "${tool}")"; then
    printf "found: %s -> %s\n" "${tool}" "${path}"
  else
    printf "missing: %s\n" "${tool}"
  fi
done

cat <<EOF

Suggested build:
  cmake -S "${ROOT_DIR}" -B "${ROOT_DIR}/build-llvm${LLVM_VERSION}" -G Ninja \\
    -DCMAKE_C_COMPILER="${LLVM_PREFIX}/bin/clang" \\
    -DCMAKE_CXX_COMPILER="${LLVM_PREFIX}/bin/clang++" \\
    -DMLIR_DIR="${LLVM_PREFIX}/lib/cmake/mlir"
  cmake --build "${ROOT_DIR}/build-llvm${LLVM_VERSION}" --target arbiter-opt arbiter-runtime-smoke

Then try:
  ARBITER_BUILD_DIR="${ROOT_DIR}/build-llvm${LLVM_VERSION}" "${ROOT_DIR}/scripts/smoke.sh"
EOF
