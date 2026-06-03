#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"
OUT_DIR="${ARBITER_BENCH_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/xindex}"
CLANGXX="${CLANGXX:-clang++}"
OPT="${OPT:-opt}"
RUNTIME_LIB="${ARBITER_RUNTIME_LIB:-${BUILD_DIR}/runtime/libarbiter_runtime.a}"
MKL_INCLUDE_DIR="${MKL_INCLUDE_DIR:-/opt/intel/oneapi/mkl/2025.3/include}"
MKL_LINK_DIR="${MKL_LINK_DIR:-/opt/intel/oneapi/mkl/2025.3/lib/intel64}"
XINDEX_EXTRA_LIBS="${XINDEX_EXTRA_LIBS:--ljemalloc -lmkl_rt -lpthread}"

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

SRC_DIR="${ROOT_DIR}/benchmark/xindex/XIndex-H"
SRC="${SRC_DIR}/ycsb_bench.cpp"

mkdir -p "${OUT_DIR}"

include_args=("-I${SRC_DIR}")
if [[ -d "${MKL_INCLUDE_DIR}" ]]; then
  include_args+=("-I${MKL_INCLUDE_DIR}")
fi

"${CLANGXX}" \
  -std=c++14 \
  -O3 \
  -gline-tables-only \
  -fno-exceptions \
  -Wall \
  -fmax-errors=5 \
  -faligned-new \
  -march=native \
  -mtune=native \
  "${include_args[@]}" \
  -emit-llvm \
  -c "${SRC}" \
  -o "${OUT_DIR}/ycsb_bench.bc"

"${OPT}" \
  -load-pass-plugin "${PLUGIN}" \
  -passes=arbiter-report-sites \
  -arbiter-report-path="${OUT_DIR}/ycsb_bench.sites.csv" \
  -disable-output \
  "${OUT_DIR}/ycsb_bench.bc"

"${OPT}" \
  -load-pass-plugin "${PLUGIN}" \
  -passes=arbiter-experiment-all-rewrite \
  "${OUT_DIR}/ycsb_bench.bc" \
  -o "${OUT_DIR}/ycsb_bench.arbiter.bc"

link_args=()
if [[ -d "${MKL_LINK_DIR}" ]]; then
  link_args+=("-L${MKL_LINK_DIR}")
fi

"${CLANGXX}" -O3 "${OUT_DIR}/ycsb_bench.arbiter.bc" "${RUNTIME_LIB}" \
  "${link_args[@]}" \
  ${XINDEX_EXTRA_LIBS} \
  ${RUNTIME_LINK_LIBS} \
  -o "${OUT_DIR}/ycsb_bench-arbiter"

echo "wrote ${OUT_DIR}/ycsb_bench-arbiter"
echo "wrote ${OUT_DIR}/ycsb_bench.sites.csv"
