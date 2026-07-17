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
XINDEX_EXPERIMENT="${ARBITER_XINDEX_EXPERIMENT:-all}"
BUILD_NATIVE="${ARBITER_BUILD_XINDEX_NATIVE:-1}"
EXPERIMENT_CONFIG="${ROOT_DIR}/scripts/xindex-experiments/${XINDEX_EXPERIMENT}.sh"

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

compile_args=(
  -std=c++14 \
  -O3 \
  -gline-tables-only \
  -fno-exceptions \
  -Wall \
  -fmax-errors=5 \
  -faligned-new \
  -march=native \
  -mtune=native \
  "${include_args[@]}"
)

link_args=()
if [[ -d "${MKL_LINK_DIR}" ]]; then
  link_args+=("-L${MKL_LINK_DIR}" "-Wl,-rpath,${MKL_LINK_DIR}")
fi

if [[ "${BUILD_NATIVE}" != "0" ]]; then
  "${CLANGXX}" \
    "${compile_args[@]}" \
    "${SRC}" \
    "${link_args[@]}" \
    ${XINDEX_EXTRA_LIBS} \
    ${RUNTIME_LINK_LIBS} \
    -o "${OUT_DIR}/ycsb_bench-native"
fi

"${CLANGXX}" \
  "${compile_args[@]}" \
  -emit-llvm \
  -c "${SRC}" \
  -o "${OUT_DIR}/ycsb_bench.bc"

"${OPT}" \
  -load-pass-plugin "${PLUGIN}" \
  -passes=arbiter-report-sites \
  -arbiter-report-path="${OUT_DIR}/ycsb_bench.sites.csv" \
  -disable-output \
  "${OUT_DIR}/ycsb_bench.bc"

if [[ ! -f "${EXPERIMENT_CONFIG}" ]]; then
  echo "unknown ARBITER_XINDEX_EXPERIMENT=${XINDEX_EXPERIMENT}" >&2
  echo "expected one of:" >&2
  for config in "${ROOT_DIR}/scripts/xindex-experiments/"*.sh; do
    [[ -e "${config}" ]] || continue
    name="$(basename "${config}")"
    echo "  ${name%.sh}" >&2
  done
  exit 1
fi

REWRITE_PASS=""
EXPERIMENT_REPORTS=()

# shellcheck source=/dev/null
source "${EXPERIMENT_CONFIG}"

if ! declare -F configure_xindex_experiment >/dev/null; then
  echo "invalid XIndex experiment config: ${EXPERIMENT_CONFIG}" >&2
  exit 1
fi

configure_xindex_experiment

if [[ -z "${REWRITE_PASS}" ]]; then
  echo "XIndex experiment ${XINDEX_EXPERIMENT} did not set REWRITE_PASS" >&2
  exit 1
fi

"${OPT}" \
  -load-pass-plugin "${PLUGIN}" \
  -passes="${REWRITE_PASS}" \
  "${OUT_DIR}/ycsb_bench.bc" \
  -o "${OUT_DIR}/ycsb_bench.arbiter.bc"

"${CLANGXX}" -O3 "${OUT_DIR}/ycsb_bench.arbiter.bc" "${RUNTIME_LIB}" \
  "${link_args[@]}" \
  ${XINDEX_EXTRA_LIBS} \
  ${RUNTIME_LINK_LIBS} \
  -o "${OUT_DIR}/ycsb_bench-arbiter"

echo "wrote ${OUT_DIR}/ycsb_bench-arbiter"
if [[ "${BUILD_NATIVE}" != "0" ]]; then
  echo "wrote ${OUT_DIR}/ycsb_bench-native"
fi
echo "wrote ${OUT_DIR}/ycsb_bench.sites.csv"
for report in "${EXPERIMENT_REPORTS[@]}"; do
  echo "wrote ${OUT_DIR}/${report}"
done
