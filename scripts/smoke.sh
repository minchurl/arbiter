#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-ninja}"
RUNTIME_SMOKE="${RUNTIME_SMOKE:-${BUILD_DIR}/bin/arbiter-runtime-smoke}"
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

find_plugin() {
  if [[ -n "${ARBITER_LLVM_PLUGIN:-}" ]]; then
    printf "%s" "${ARBITER_LLVM_PLUGIN}"
  elif [[ -f "${BUILD_DIR}/lib/libArbiterLLVMPlugin.so" ]]; then
    printf "%s" "${BUILD_DIR}/lib/libArbiterLLVMPlugin.so"
  elif [[ -f "${BUILD_DIR}/lib/ArbiterLLVMPlugin.so" ]]; then
    printf "%s" "${BUILD_DIR}/lib/ArbiterLLVMPlugin.so"
  elif [[ -f "${BUILD_DIR}/lib/ArbiterLLVMPlugin.dylib" ]]; then
    printf "%s" "${BUILD_DIR}/lib/ArbiterLLVMPlugin.dylib"
  else
    return 1
  fi
}

CLANG="${CLANG:-$(find_tool clang)}"
OPT="${OPT:-$(find_tool opt)}"
LLVM_DIS="${LLVM_DIS:-$(find_tool llvm-dis)}"
PLUGIN="$(find_plugin)"

if [[ ! -x "${RUNTIME_SMOKE}" ]]; then
  echo "smoke: arbiter-runtime-smoke not found at ${RUNTIME_SMOKE}" >&2
  echo "smoke: build first, or set RUNTIME_SMOKE=/path/to/arbiter-runtime-smoke" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

cat >"${tmpdir}/smoke.c" <<'EOF'
extern void *malloc(unsigned long);
extern void free(void *);
extern void *mmap(void *, unsigned long, int, int, int, long);
extern int munmap(void *, unsigned long);

void smoke_heap(void) {
  void *ptr = malloc(16);
  free(ptr);
}

void smoke_mmap(void) {
  void *ptr = mmap((void *)0, 4096, 3, 0x22, -1, 0);
  munmap(ptr, 4096);
}
EOF

printf "smoke: compile llvm ir\n"
"${CLANG}" -O0 -gline-tables-only -emit-llvm -c "${tmpdir}/smoke.c" \
  -o "${tmpdir}/smoke.bc"

printf "smoke: report sites\n"
"${OPT}" -load-pass-plugin "${PLUGIN}" \
  -passes=arbiter-report-sites \
  -disable-output \
  "${tmpdir}/smoke.bc"

printf "smoke: rewrite allocations\n"
"${OPT}" -load-pass-plugin "${PLUGIN}" \
  -passes=arbiter-experiment-all-rewrite \
  "${tmpdir}/smoke.bc" \
  -o "${tmpdir}/smoke.arbiter.bc"

"${LLVM_DIS}" "${tmpdir}/smoke.arbiter.bc" -o "${tmpdir}/smoke.arbiter.ll"

grep -q "arbiter_alloc_site" "${tmpdir}/smoke.arbiter.ll"
grep -q "arbiter_free_maybe" "${tmpdir}/smoke.arbiter.ll"
grep -q "arbiter_mmap_site" "${tmpdir}/smoke.arbiter.ll"
grep -q "arbiter_munmap_maybe" "${tmpdir}/smoke.arbiter.ll"

printf "smoke: runtime fallback\n"
"${RUNTIME_SMOKE}"

printf "smoke: ok\n"
