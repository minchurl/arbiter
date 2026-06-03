#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 input.bc [report.csv]" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"
OPT="${OPT:-opt}"
INPUT="$1"
REPORT="${2:-allocation-sites.csv}"

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

"${OPT}" \
  -load-pass-plugin "${PLUGIN}" \
  -passes=arbiter-report-sites \
  -arbiter-report-path="${REPORT}" \
  -disable-output \
  "${INPUT}"

echo "wrote ${REPORT}"
