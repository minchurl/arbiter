#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-ninja}"
ARBITER_OPT="${ARBITER_OPT:-${BUILD_DIR}/bin/arbiter-opt}"
RUNTIME_SMOKE="${RUNTIME_SMOKE:-${BUILD_DIR}/bin/arbiter-runtime-smoke}"
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
  echo "smoke: arbiter-opt not found at ${ARBITER_OPT}" >&2
  echo "smoke: build first, or set ARBITER_OPT=/path/to/arbiter-opt" >&2
  exit 1
fi

if [[ ! -x "${RUNTIME_SMOKE}" ]]; then
  echo "smoke: arbiter-runtime-smoke not found at ${RUNTIME_SMOKE}" >&2
  echo "smoke: build first, or set RUNTIME_SMOKE=/path/to/arbiter-runtime-smoke" >&2
  exit 1
fi

if ! command -v "${FILECHECK_TOOL}" >/dev/null 2>&1; then
  echo "smoke: FileCheck not found" >&2
  echo "smoke: set FILECHECK=/path/to/FileCheck if it is outside PATH" >&2
  exit 1
fi

run_filecheck() {
  local name="$1"
  local input="$2"
  shift 2

  printf "smoke: %s\n" "${name}"
  "${ARBITER_OPT}" "$@" "${input}" | "${FILECHECK_TOOL}" "${input}"
}

run_filecheck \
  "select objects" \
  "${ROOT_DIR}/tests/Transforms/select-objects.mlir" \
  --arbiter-select-objects

run_filecheck \
  "rewrite allocations" \
  "${ROOT_DIR}/tests/Transforms/rewrite-allocations.mlir" \
  --arbiter-select-objects \
  --arbiter-rewrite-allocations

printf "smoke: runtime fallback\n"
"${RUNTIME_SMOKE}"

printf "smoke: ok\n"
