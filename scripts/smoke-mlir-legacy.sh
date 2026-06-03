#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-ninja}"
ARBITER_OPT="${ARBITER_OPT:-${BUILD_DIR}/bin/arbiter-opt}"
LLVM_VERSION="${LLVM_VERSION:-18}"
LLVM_PREFIX="${LLVM_PREFIX:-/usr/lib/llvm-${LLVM_VERSION}}"

if [[ -n "${FILECHECK:-}" ]]; then
  FILECHECK_TOOL="${FILECHECK}"
elif [[ -x "${LLVM_PREFIX}/bin/FileCheck" ]]; then
  FILECHECK_TOOL="${LLVM_PREFIX}/bin/FileCheck"
elif command -v "FileCheck-${LLVM_VERSION}" >/dev/null 2>&1; then
  FILECHECK_TOOL="FileCheck-${LLVM_VERSION}"
else
  FILECHECK_TOOL="FileCheck"
fi

if [[ ! -x "${ARBITER_OPT}" ]]; then
  echo "smoke-mlir-legacy: arbiter-opt not found at ${ARBITER_OPT}" >&2
  echo "smoke-mlir-legacy: build with -DARBITER_ENABLE_MLIR_LEGACY=ON first" >&2
  exit 1
fi

if ! command -v "${FILECHECK_TOOL}" >/dev/null 2>&1; then
  echo "smoke-mlir-legacy: FileCheck not found" >&2
  echo "smoke-mlir-legacy: set FILECHECK=/path/to/FileCheck if needed" >&2
  exit 1
fi

run_filecheck() {
  local name="$1"
  local input="$2"
  shift 2

  printf "smoke-mlir-legacy: %s\n" "${name}"
  "${ARBITER_OPT}" "$@" "${input}" | "${FILECHECK_TOOL}" "${input}"
}

run_negative_filecheck() {
  local name="$1"
  local input="$2"
  shift 2

  printf "smoke-mlir-legacy: %s\n" "${name}"
  local output
  output="$(mktemp)"
  if "${ARBITER_OPT}" "$@" "${input}" >"${output}" 2>&1; then
    echo "smoke-mlir-legacy: expected failure for ${name}" >&2
    rm -f "${output}"
    exit 1
  fi
  "${FILECHECK_TOOL}" "${input}" <"${output}"
  rm -f "${output}"
}

run_filecheck \
  "select objects" \
  "${ROOT_DIR}/tests/mlir-legacy/select-objects.mlir" \
  --arbiter-select-objects

run_filecheck \
  "rewrite allocations" \
  "${ROOT_DIR}/tests/mlir-legacy/rewrite-allocations.mlir" \
  --arbiter-select-objects \
  --arbiter-rewrite-allocations

run_filecheck \
  "lower to runtime" \
  "${ROOT_DIR}/tests/mlir-legacy/lower-to-runtime.mlir" \
  --arbiter-select-objects \
  --arbiter-rewrite-allocations \
  --arbiter-lower-to-runtime

run_negative_filecheck \
  "lower to runtime rejects non-identity memref layout" \
  "${ROOT_DIR}/tests/mlir-legacy/lower-to-runtime-invalid.mlir" \
  --arbiter-lower-to-runtime

printf "smoke-mlir-legacy: ok\n"
