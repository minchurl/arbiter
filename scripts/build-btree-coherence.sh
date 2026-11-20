#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ARBITER_BUILD_DIR:-${ROOT_DIR}/build-llvm18}"
OUT_DIR="${ARBITER_BENCH_BUILD_DIR:-${ROOT_DIR}/build/arbiter-bench/btree-coherence}"
btree="${VMITOSIS_DIR:-${HOME}/vmitosis-workloads}"
micro="${MICROBENCH_DIR:-${HOME}/microbench}"
adapters="${ROOT_DIR}/benchmark/btree-coherence"
prefix="${LLVM_PREFIX:-/usr/lib/llvm-18}"
if [[ -z "${LLVM_PREFIX:-}" && ! -x "${prefix}/bin/clang" && -x "${ROOT_DIR}/.tools/llvm-18.1.8/bin/clang" ]]; then
  prefix="${ROOT_DIR}/.tools/llvm-18.1.8"
  shared="${ROOT_DIR}/.tools/libllvm18-root/usr/lib/x86_64-linux-gnu"
  export LD_LIBRARY_PATH="${ROOT_DIR}/.tools/libtinfo5-root/lib/x86_64-linux-gnu:${shared}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  export LIBRARY_PATH="${ROOT_DIR}/.tools/libstdcxx:${shared}${LIBRARY_PATH:+:${LIBRARY_PATH}}"
  OPT="${OPT:-${ROOT_DIR}/.tools/llvm18-apt-root/usr/bin/opt-18}"
fi
CLANG="${CLANG:-${prefix}/bin/clang}"
CLANGXX="${CLANGXX:-${prefix}/bin/clang++}"
OPT="${OPT:-${prefix}/bin/opt}"
PLUGIN="${ARBITER_LLVM_PLUGIN:-${BUILD_DIR}/lib/ArbiterLLVMPlugin.so}"
runtime="${BUILD_DIR}/runtime/libarbiter_runtime.a"
if [[ "${ARBITER_BENCH_SELECTION:-policy}" != policy ]]; then
  echo "Manual placement is archived at a2151db; this build uses automatic selection" >&2
  exit 1
fi
ARBITER_HITM_SEED_CONFIG="${ARBITER_HITM_SEED_CONFIG:-${ROOT_DIR}/configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config}"
# shellcheck source=xindex-experiments/hitm-seed.sh
source "${ROOT_DIR}/scripts/xindex-experiments/hitm-seed.sh"

mkdir -p "${OUT_DIR}"
cmake --build "${BUILD_DIR}" --target ArbiterLLVMPlugin arbiter_runtime
ccflags=(-std=gnu99 -O3 -gline-tables-only -fopenmp)
cxxflags=(-std=c++17 -O2 -gline-tables-only -march=native -pthread)
entry_bytes="${ARBITER_MICRO_ENTRY_BYTES:-32}"
epoch_store="${ARBITER_MICRO_EPOCH_STORE:-1}"
if [[ ! "$entry_bytes" =~ ^(32|64)$ || ! "$epoch_store" =~ ^[01]$ ]]; then
  echo "ARBITER_MICRO_ENTRY_BYTES must be 32 or 64; ARBITER_MICRO_EPOCH_STORE must be 0 or 1" >&2
  exit 1
fi
cxxflags+=(-DARBITER_MICRO_ENTRY_BYTES="$entry_bytes" -DARBITER_MICRO_EPOCH_STORE="$epoch_store")
if [[ -d "${ROOT_DIR}/.tools/libstdcxx" && "${prefix}" == "${ROOT_DIR}/.tools/"* ]]; then
  cxxflags+=(--gcc-install-dir="$(dirname "$(gcc -print-libgcc-file-name)")")
fi
libs=(-Wl,--no-as-needed -ljemalloc -lnuma -pthread)
omp=(-fopenmp "-Wl,-rpath,${prefix}/lib")

# Both matched controls and placement builds include the same post-timing checks.
patch --batch --forward --fuzz=0 -o "${OUT_DIR}/btree.c" "${btree}/btree/btree.c" "${adapters}/btree.patch"
patch --batch --forward --fuzz=0 -o "${OUT_DIR}/coherence_noise.cpp" "${micro}/coherence_noise.cpp" "${adapters}/coherence-noise.patch"
"${CLANG}" -O3 -march=native -fopenmp -DDISABLE_SIGNAL_IN_MAIN -c "${btree}/common/main-mt.c" -o "${OUT_DIR}/driver.o"
"${CLANG}" "${ccflags[@]}" -I"${adapters}" -emit-llvm -c "${OUT_DIR}/btree.c" -o "${OUT_DIR}/btree-native.bc"
configure_hitm_seed_experiment btree-native
"${OPT}" -load-pass-plugin "${PLUGIN}" -passes="${REWRITE_PASS}" "${REWRITE_ARGS[@]}" \
  "${OUT_DIR}/btree-native.bc" -o "${OUT_DIR}/btree-placed.bc"
for mode in native placed; do
  "${CLANG}" -O3 -c "${OUT_DIR}/btree-${mode}.bc" -o "${OUT_DIR}/btree-${mode}.o"
  "${CLANGXX}" "${OUT_DIR}/driver.o" "${OUT_DIR}/btree-${mode}.o" "${runtime}" \
    "${omp[@]}" "${libs[@]}" -o "${OUT_DIR}/btree-${mode}"
done

"${CLANGXX}" "${cxxflags[@]}" -I"${adapters}" -emit-llvm -c "${OUT_DIR}/coherence_noise.cpp" -o "${OUT_DIR}/micro-native.bc"
"${OPT}" -load-pass-plugin "${PLUGIN}" -passes=arbiter-report-sites \
  -arbiter-report-path="${OUT_DIR}/micro-sites.csv" -disable-output "${OUT_DIR}/micro-native.bc"
configure_hitm_seed_experiment micro-native
"${OPT}" -load-pass-plugin "${PLUGIN}" -passes=arbiter-experiment-hitm-seed-rewrite \
  "${REWRITE_ARGS[@]}" "${OUT_DIR}/micro-native.bc" -o "${OUT_DIR}/micro-placed.bc"
for mode in native placed; do
  "${CLANGXX}" "${cxxflags[@]}" "${OUT_DIR}/micro-${mode}.bc" "${runtime}" "${libs[@]}" -o "${OUT_DIR}/micro-${mode}"
done
python3 - "${OUT_DIR}" <<'PYTHON'
import csv
import json
import sys
from pathlib import Path
out = Path(sys.argv[1])
def selected(stem):
    with (out / f"{stem}-native.hitm-seed-sites.csv").open() as stream:
        return {int(row["site_id"]) for row in csv.DictReader(stream) if row["selected"] == "yes"}
if selected("btree"):
    sys.exit("B-tree validation needs a page probe for the newly selected allocation")
source = out / "coherence_noise.cpp"
lines = source.read_text().splitlines()
known = {}
with (out / "micro-sites.csv").open() as stream:
    for row in csv.DictReader(stream):
        if Path(row["file"]).resolve() != source.resolve() or row["kind"] != "cxx-new-array":
            continue
        line = lines[int(row["line"]) - 1]
        for name, allocation in (("table", "g_table = new Entry["), ("ballast", "g_ballast = new uint64_t[")):
            if allocation in line:
                if name in known:
                    sys.exit(f"ambiguous allocation site for {name}")
                known[name] = int(row["site_id"])
chosen = selected("micro")
if set(known) != {"table", "ballast"} or chosen - set(known.values()):
    sys.exit("Microbenchmark validation needs a page probe for the newly selected allocation")
objects = {"btree": {}, "micro": {name: site for name, site in known.items() if site in chosen}}
(out / "selected-objects.json").write_text(json.dumps(objects, indent=2) + "\n")
PYTHON
sha256sum "${btree}/btree/btree.c" "${btree}/common/main-mt.c" "${micro}/coherence_noise.cpp" \
  "${ARBITER_HITM_SEED_CONFIG}" "${PLUGIN}" "${runtime}" "${OUT_DIR}/selected-objects.json" \
  "${adapters}/coherence-noise.patch" "${adapters}/perf-window.h" "${OUT_DIR}/coherence_noise.cpp" \
  "${OUT_DIR}"/{btree,micro}-{native,placed} >"${OUT_DIR}/inputs.sha256"
printf '{"entry_bytes":%s,"epoch_store":%s}\n' "$entry_bytes" "$epoch_store" >"${OUT_DIR}/micro-layout.json"
printf 'Built B-tree and coherence_noise in %s (automatic selection)\n' "${OUT_DIR}"
