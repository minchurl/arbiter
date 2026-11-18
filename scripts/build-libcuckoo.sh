#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"
OUT_DIR="${ARBITER_BENCH_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/libcuckoo}"
SOURCE_DIR="${LIBCUCKOO_SOURCE_DIR:-${ROOT_DIR}/benchmark/libcuckoo/libcuckoo-upstream}"
revision=0dd0b4d68fef76791a17950fde1a24f2328a58fe
if [[ ! -d "${SOURCE_DIR}" ]]; then
  git clone https://github.com/efficient/libcuckoo.git "${SOURCE_DIR}"
  git -C "${SOURCE_DIR}" checkout "${revision}"
fi
if [[ "$(git -C "${SOURCE_DIR}" rev-parse HEAD)" != "$revision" || -n "$(git -C "${SOURCE_DIR}" status --porcelain)" ]]; then
  echo "Expected clean libcuckoo revision $revision at $SOURCE_DIR" >&2; exit 1
fi
prefix="${LLVM_PREFIX:-/usr/lib/llvm-18}"
if [[ -z "${LLVM_PREFIX:-}" && ! -x "${prefix}/bin/clang++" && -x "${ROOT_DIR}/.tools/llvm-18.1.8/bin/clang++" ]]; then
  prefix="${ROOT_DIR}/.tools/llvm-18.1.8"
  shared="${ROOT_DIR}/.tools/libllvm18-root/usr/lib/x86_64-linux-gnu"
  export LD_LIBRARY_PATH="${ROOT_DIR}/.tools/libtinfo5-root/lib/x86_64-linux-gnu:${shared}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  export LIBRARY_PATH="${ROOT_DIR}/.tools/libstdcxx:${shared}${LIBRARY_PATH:+:${LIBRARY_PATH}}"
  OPT="${OPT:-${ROOT_DIR}/.tools/llvm18-apt-root/usr/bin/opt-18}"
fi
CLANGXX="${CLANGXX:-${prefix}/bin/clang++}"
OPT="${OPT:-${prefix}/bin/opt}"
PLUGIN="${ARBITER_LLVM_PLUGIN:-${BUILD_DIR}/lib/ArbiterLLVMPlugin.so}"
ARBITER_HITM_SEED_CONFIG="${ARBITER_HITM_SEED_CONFIG:-${ROOT_DIR}/configs/hitm-seed/policy-candidates/published-rmw-size-tiebreaker.config}"
source "${ROOT_DIR}/scripts/xindex-experiments/hitm-seed.sh"
mkdir -p "${OUT_DIR}"
cmake --build "${BUILD_DIR}" --target ArbiterLLVMPlugin arbiter_runtime
flags=(-std=c++17 -O2 -gline-tables-only -march=native -pthread)
if [[ "$prefix" == "${ROOT_DIR}/.tools/"* ]]; then
  flags+=(--gcc-install-dir="$(dirname "$(gcc -print-libgcc-file-name)")")
fi
cmake -S "${SOURCE_DIR}" -B "${OUT_DIR}/upstream" -G Ninja \
  -DCMAKE_CXX_COMPILER="${CLANGXX}" -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF \
  -DBUILD_UNIT_TESTS=OFF -DBUILD_STRESS_TESTS=OFF -DBUILD_UNIVERSAL_BENCHMARK=ON \
  >"${OUT_DIR}/configure.log"
includes=(-I"${SOURCE_DIR}" -I"${SOURCE_DIR}/tests" -I"${OUT_DIR}/upstream/tests")
for stem in universal contention; do
  source="${ROOT_DIR}/benchmark/libcuckoo/contention.cpp"
  defines=()
  if [[ "$stem" == universal ]]; then
    source="${SOURCE_DIR}/tests/universal-benchmark/universal_benchmark.cc"
    defines=(-DKEY=uint64_t -DVALUE=uint64_t -DLIBCUCKOO -DNDEBUG)
  fi
  "${CLANGXX}" "${flags[@]}" "${includes[@]}" "${defines[@]}" -emit-llvm -c "$source" -o "${OUT_DIR}/${stem}.bc"
  "${OPT}" -load-pass-plugin "${PLUGIN}" -passes=arbiter-report-sites \
    -arbiter-report-path="${OUT_DIR}/${stem}.sites.csv" -disable-output "${OUT_DIR}/${stem}.bc"
  configure_hitm_seed_experiment "$stem"
  "${OPT}" -load-pass-plugin "${PLUGIN}" -passes="${REWRITE_PASS}" "${REWRITE_ARGS[@]}" \
    "${OUT_DIR}/${stem}.bc" -o "${OUT_DIR}/${stem}-placed.bc"
  for mode in native placed; do
    bitcode="${OUT_DIR}/${stem}.bc"
    [[ "$mode" == placed ]] && bitcode="${OUT_DIR}/${stem}-placed.bc"
    "${CLANGXX}" "${flags[@]}" "$bitcode" "${BUILD_DIR}/runtime/libarbiter_runtime.a" \
      -Wl,--no-as-needed -ljemalloc -lnuma -o "${OUT_DIR}/${stem}-${mode}"
  done
done
printf '%s\n' "$revision" > "${OUT_DIR}/upstream-commit.txt"
sha256sum "$PLUGIN" "${BUILD_DIR}/runtime/libarbiter_runtime.a" "$ARBITER_HITM_SEED_CONFIG" \
  "${ROOT_DIR}/benchmark/libcuckoo/contention.cpp" "${OUT_DIR}"/{universal,contention}-{native,placed} \
  > "${OUT_DIR}/inputs.sha256"
echo "Built libcuckoo in ${OUT_DIR}"
