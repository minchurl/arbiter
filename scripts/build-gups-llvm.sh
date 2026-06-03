#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"
OUT_DIR="${ARBITER_BENCH_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/gups}"
CLANG="${CLANG:-clang}"
LLVM_LINK="${LLVM_LINK:-llvm-link}"
OPT="${OPT:-opt}"
RUNTIME_LIB="${ARBITER_RUNTIME_LIB:-${BUILD_DIR}/runtime/libarbiter_runtime.a}"
TARGET="${1:-gups}"

DEFAULT_RUNTIME_LINK_LIBS=""
if [[ "$(uname -s)" == "Linux" ]]; then
  DEFAULT_RUNTIME_LINK_LIBS="-lnuma"
fi
RUNTIME_LINK_LIBS="${ARBITER_RUNTIME_LINK_LIBS:-${DEFAULT_RUNTIME_LINK_LIBS}}"

if [[ -n "${ARBITER_LLVM_PLUGIN:-}" ]]; then
  PLUGIN="${ARBITER_LLVM_PLUGIN}"
elif [[ -f "${BUILD_DIR}/lib/libArbiterLLVMPlugin.so" ]]; then
  PLUGIN="${BUILD_DIR}/lib/libArbiterLLVMPlugin.so"
elif [[ -f "${BUILD_DIR}/lib/ArbiterLLVMPlugin.so" ]]; then
  PLUGIN="${BUILD_DIR}/lib/ArbiterLLVMPlugin.so"
elif [[ -f "${BUILD_DIR}/lib/ArbiterLLVMPlugin.dylib" ]]; then
  PLUGIN="${BUILD_DIR}/lib/ArbiterLLVMPlugin.dylib"
else
  PLUGIN="${BUILD_DIR}/lib/libArbiterLLVMPlugin.so"
fi

SRC_DIR="${ROOT_DIR}/benchmark/gups"
SRC="${SRC_DIR}/${TARGET}.c"
if [[ ! -f "${SRC}" ]]; then
  echo "unknown GUPS target: ${TARGET}" >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

"${CLANG}" -O3 -gline-tables-only -emit-llvm -c "${SRC}" \
  -o "${OUT_DIR}/${TARGET}.bc"
"${CLANG}" -O3 -gline-tables-only -emit-llvm -c "${SRC_DIR}/zipf.c" \
  -o "${OUT_DIR}/zipf.bc"
"${CLANG}" -O3 -gline-tables-only -emit-llvm -c "${SRC_DIR}/timer.c" \
  -o "${OUT_DIR}/timer.bc"

"${LLVM_LINK}" \
  "${OUT_DIR}/${TARGET}.bc" \
  "${OUT_DIR}/zipf.bc" \
  "${OUT_DIR}/timer.bc" \
  -o "${OUT_DIR}/${TARGET}.linked.bc"

"${OPT}" \
  -load-pass-plugin "${PLUGIN}" \
  -passes=arbiter-report-sites \
  -arbiter-report-path="${OUT_DIR}/${TARGET}.sites.csv" \
  -disable-output \
  "${OUT_DIR}/${TARGET}.linked.bc"

"${OPT}" \
  -load-pass-plugin "${PLUGIN}" \
  -passes=arbiter-experiment-all-rewrite \
  "${OUT_DIR}/${TARGET}.linked.bc" \
  -o "${OUT_DIR}/${TARGET}.arbiter.bc"

"${CLANG}" -O3 "${OUT_DIR}/${TARGET}.arbiter.bc" "${RUNTIME_LIB}" \
  -lm -lpthread ${RUNTIME_LINK_LIBS} \
  -o "${OUT_DIR}/${TARGET}-arbiter"

echo "wrote ${OUT_DIR}/${TARGET}-arbiter"
echo "wrote ${OUT_DIR}/${TARGET}.sites.csv"
