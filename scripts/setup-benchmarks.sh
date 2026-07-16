#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLVM_VERSION="${LLVM_VERSION:-18}"
LLVM_PREFIX="${LLVM_PREFIX:-/usr/lib/llvm-${LLVM_VERSION}}"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm${LLVM_VERSION}}"
RUN_SMOKE=1
RESTORE_DATA=1
BUILD_ARBITER=1
BUILD_BENCHMARKS=1

usage() {
  cat <<EOF
usage: $0 [--no-smoke] [--no-data] [--no-arbiter-build] [--no-benchmark-build]

Fresh-clone benchmark setup:
  1. Pull Git LFS benchmark chunks.
  2. Restore full XIndex/YCSB .dat traces.
  3. Configure/build Arbiter's LLVM plugin and runtime.
  4. Build GUPS and XIndex benchmark variants.
  5. Run short GUPS and XIndex/YCSB smoke checks.

Environment:
  LLVM_VERSION       LLVM major version, default 18
  LLVM_PREFIX        LLVM install prefix, default /usr/lib/llvm-\$LLVM_VERSION
  ARBITER_BUILD_DIR  Arbiter build directory, default build-llvm\$LLVM_VERSION
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-smoke)
      RUN_SMOKE=0
      shift
      ;;
    --no-data)
      RESTORE_DATA=0
      shift
      ;;
    --no-arbiter-build)
      BUILD_ARBITER=0
      shift
      ;;
    --no-benchmark-build)
      BUILD_BENCHMARKS=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

find_tool() {
  local tool="$1"

  if [[ -x "${LLVM_PREFIX}/bin/${tool}" ]]; then
    printf "%s" "${LLVM_PREFIX}/bin/${tool}"
    return 0
  fi

  if command -v "${tool}-${LLVM_VERSION}" >/dev/null 2>&1; then
    command -v "${tool}-${LLVM_VERSION}"
    return 0
  fi

  command -v "${tool}" 2>/dev/null
}

require_tool() {
  local tool="$1"
  local hint="$2"

  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "missing required tool: ${tool}" >&2
    echo "hint: ${hint}" >&2
    exit 1
  fi
}

require_path_tool() {
  local var_name="$1"
  local tool="$2"
  local hint="$3"
  local path

  if ! path="$(find_tool "${tool}")"; then
    echo "missing required tool: ${tool}" >&2
    echo "hint: ${hint}" >&2
    exit 1
  fi

  printf -v "${var_name}" "%s" "${path}"
}

step() {
  printf "\n==> %s\n" "$1"
}

require_tool git "install git"
require_tool cmake "sudo apt install cmake"
require_tool ninja "sudo apt install ninja-build"
require_tool make "sudo apt install make"
require_tool gcc "sudo apt install gcc"
require_tool zstd "sudo apt install zstd"

require_path_tool CLANG_BIN clang "install clang-${LLVM_VERSION} or set LLVM_PREFIX"
require_path_tool CLANGXX_BIN clang++ "install clang++-${LLVM_VERSION} or set LLVM_PREFIX"
require_path_tool OPT_BIN opt "install llvm-${LLVM_VERSION} tools or set LLVM_PREFIX"
require_path_tool LLVM_LINK_BIN llvm-link "install llvm-${LLVM_VERSION} tools or set LLVM_PREFIX"

export CLANG="${CLANG:-${CLANG_BIN}}"
export CLANGXX="${CLANGXX:-${CLANGXX_BIN}}"
export OPT="${OPT:-${OPT_BIN}}"
export LLVM_LINK="${LLVM_LINK:-${LLVM_LINK_BIN}}"
export ARBITER_BUILD_DIR="${BUILD_DIR}"

if [[ "${RESTORE_DATA}" == "1" ]]; then
  step "Restore XIndex/YCSB benchmark data"
  require_tool git-lfs "install git-lfs, then rerun this script"
  git lfs install --local
  git lfs pull --include="benchmark/xindex/YCSB/xindex_dat/github-parts/**" --exclude=""
  "${ROOT_DIR}/scripts/restore-xindex-ycsb-data.sh"
fi

if [[ "${BUILD_ARBITER}" == "1" ]]; then
  step "Build Arbiter LLVM plugin and runtime"
  cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DCMAKE_C_COMPILER="${CLANG}" \
    -DCMAKE_CXX_COMPILER="${CLANGXX}"
  cmake --build "${BUILD_DIR}" --target \
    ArbiterLLVMPlugin \
    arbiter_runtime \
    arbiter-runtime-smoke
fi

if [[ "${BUILD_BENCHMARKS}" == "1" ]]; then
  step "Build GUPS native and Arbiter variants"
  make -C "${ROOT_DIR}/benchmark/gups" gups
  "${ROOT_DIR}/scripts/build-gups-llvm.sh"

  step "Build XIndex native and Arbiter variants"
  "${ROOT_DIR}/scripts/build-xindex-llvm.sh"
fi

if [[ "${RUN_SMOKE}" == "1" ]]; then
  step "Run short GUPS smoke checks"
  GUPS_ARGS="1 1000 20 8 10 90" "${ROOT_DIR}/scripts/run-gups-arbiter.sh" native
  GUPS_ARGS="1 1000 20 8 10 90" "${ROOT_DIR}/scripts/run-gups-arbiter.sh" local

  step "Prepare short XIndex/YCSB smoke traces"
  "${ROOT_DIR}/scripts/prepare-xindex-ycsb-smoke-data.sh"

  step "Run short XIndex/YCSB smoke checks"
  XINDEX_FG=2 \
    XINDEX_ITERATION=1 \
    YCSB_LOAD_PATH="${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_dat/xindex_load_ycsb_a.small.dat" \
    YCSB_TX_PATH="${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_dat/xindex_transaction_ycsb_a.small.dat" \
    "${ROOT_DIR}/scripts/run-xindex-arbiter.sh" native

  XINDEX_FG=2 \
    XINDEX_ITERATION=1 \
    YCSB_LOAD_PATH="${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_dat/xindex_load_ycsb_a.small.dat" \
    YCSB_TX_PATH="${ROOT_DIR}/build/arbiter-bench/xindex/ycsb_dat/xindex_transaction_ycsb_a.small.dat" \
    "${ROOT_DIR}/scripts/run-xindex-arbiter.sh" local
fi

cat <<EOF

Benchmark setup complete.

Run full local checks:
  ./scripts/run-gups-arbiter.sh local
  ./scripts/run-xindex-arbiter.sh local

Run remote placement checks:
  ARBITER_TARGET_NODE=<node> ./scripts/run-gups-arbiter.sh remote
  ARBITER_TARGET_NODE=<node> ./scripts/run-xindex-arbiter.sh remote
EOF
