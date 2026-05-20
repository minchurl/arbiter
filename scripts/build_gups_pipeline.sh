#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLVM_VERSION="${LLVM_VERSION:-18}"
LLVM_PREFIX="${LLVM_PREFIX:-/usr/lib/llvm-${LLVM_VERSION}}"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm${LLVM_VERSION}}"

GUPS_CPP="${GUPS_CPP:-${ROOT_DIR}/benchmarks/gups/gups.cpp}"
OUT_DIR="${GUPS_OUT_DIR:-${BUILD_DIR}/benchmarks/gups}"
ARBITER_OPT="${ARBITER_OPT:-${BUILD_DIR}/bin/arbiter-opt}"
RUNTIME_LIB="${ARBITER_RUNTIME_LIB:-${BUILD_DIR}/runtime/libarbiter_runtime.a}"

find_tool_optional() {
  local name="$1"
  if [[ -x "${LLVM_PREFIX}/bin/${name}" ]]; then
    printf "%s" "${LLVM_PREFIX}/bin/${name}"
    return 0
  fi
  if command -v "${name}-${LLVM_VERSION}" >/dev/null 2>&1; then
    command -v "${name}-${LLVM_VERSION}"
    return 0
  fi
  command -v "${name}" 2>/dev/null || true
}

CGEIST="${CGEIST:-$(find_tool_optional cgeist)}"
MLIR_OPT="${MLIR_OPT:-$(find_tool_optional mlir-opt)}"
MLIR_TRANSLATE="${MLIR_TRANSLATE:-$(find_tool_optional mlir-translate)}"
CLANGXX="${CLANGXX:-$(find_tool_optional clang++)}"

require_executable() {
  local name="$1"
  local path="$2"
  if [[ -z "${path}" || ! -x "${path}" ]]; then
    echo "build_gups_pipeline: ${name} not found" >&2
    exit 1
  fi
}

require_file() {
  local name="$1"
  local path="$2"
  if [[ ! -f "${path}" ]]; then
    echo "build_gups_pipeline: ${name} not found at ${path}" >&2
    exit 1
  fi
}

require_executable cgeist "${CGEIST}"
require_executable mlir-opt "${MLIR_OPT}"
require_executable mlir-translate "${MLIR_TRANSLATE}"
require_executable clang++ "${CLANGXX}"
require_executable arbiter-opt "${ARBITER_OPT}"
require_file "runtime library" "${RUNTIME_LIB}"
require_file "GUPS C++ source" "${GUPS_CPP}"

mkdir -p "${OUT_DIR}"

CGEIST_MLIR="${OUT_DIR}/gups-cgeist.mlir"
SYSTEM_LLVM_MLIR="${OUT_DIR}/gups-system.llvm.mlir"
SYSTEM_LL="${OUT_DIR}/gups-system.ll"
ARBITER_LLVM_MLIR="${OUT_DIR}/gups-arbiter.llvm.mlir"
ARBITER_LL="${OUT_DIR}/gups-arbiter.ll"

"${CGEIST}" "${GUPS_CPP}" \
  -DGUPS_FRONTEND_ONLY \
  -function=gups_kernel \
  -S \
  -o "${CGEIST_MLIR}"

if ! grep -Eq 'memref\.alloc([^a-zA-Z0-9_]|$)' "${CGEIST_MLIR}"; then
  echo "build_gups_pipeline: cgeist output did not contain memref.alloc" >&2
  echo "build_gups_pipeline: Arbiter needs a frontend-visible allocation to rewrite" >&2
  exit 1
fi

"${MLIR_OPT}" \
  --convert-arith-to-llvm \
  --finalize-memref-to-llvm \
  --convert-func-to-llvm \
  --reconcile-unrealized-casts \
  "${CGEIST_MLIR}" \
  -o "${SYSTEM_LLVM_MLIR}"

"${MLIR_TRANSLATE}" --mlir-to-llvmir "${SYSTEM_LLVM_MLIR}" -o "${SYSTEM_LL}"

"${CLANGXX}" -O3 -DGUPS_EXTERNAL_KERNEL "${GUPS_CPP}" "${SYSTEM_LL}" \
  -o "${OUT_DIR}/gups-system"

"${ARBITER_OPT}" \
  --arbiter-select-objects \
  --arbiter-rewrite-allocations \
  --arbiter-lower-to-runtime \
  "${CGEIST_MLIR}" \
  -o "${ARBITER_LLVM_MLIR}"

if ! grep -q 'arbiter_alloc' "${ARBITER_LLVM_MLIR}"; then
  echo "build_gups_pipeline: Arbiter lowering did not emit arbiter_alloc" >&2
  exit 1
fi

"${MLIR_TRANSLATE}" --mlir-to-llvmir "${ARBITER_LLVM_MLIR}" -o "${ARBITER_LL}"

"${CLANGXX}" -O3 -DGUPS_EXTERNAL_KERNEL "${GUPS_CPP}" "${ARBITER_LL}" \
  "${RUNTIME_LIB}" -o "${OUT_DIR}/gups-arbiter"

printf "built: %s\n" "${OUT_DIR}/gups-system"
printf "built: %s\n" "${OUT_DIR}/gups-arbiter"
