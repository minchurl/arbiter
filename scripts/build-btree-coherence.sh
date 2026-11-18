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
selection="${ARBITER_BENCH_SELECTION:-policy}"
if [[ "${selection}" != targeted && "${selection}" != policy ]]; then
  echo "ARBITER_BENCH_SELECTION must be targeted or policy" >&2
  exit 1
fi
ARBITER_HITM_SEED_CONFIG="${ARBITER_HITM_SEED_CONFIG:-${ROOT_DIR}/configs/hitm-seed/policy-candidates/published-rmw-size-tiebreaker.config}"
# shellcheck source=xindex-experiments/hitm-seed.sh
source "${ROOT_DIR}/scripts/xindex-experiments/hitm-seed.sh"

mkdir -p "${OUT_DIR}"
cmake --build "${BUILD_DIR}" --target ArbiterLLVMPlugin arbiter_runtime
ccflags=(-std=gnu99 -O3 -gline-tables-only -fopenmp)
cxxflags=(-std=c++17 -O2 -gline-tables-only -march=native -pthread)
if [[ -d "${ROOT_DIR}/.tools/libstdcxx" && "${prefix}" == "${ROOT_DIR}/.tools/"* ]]; then
  cxxflags+=(--gcc-install-dir="$(dirname "$(gcc -print-libgcc-file-name)")")
fi
libs=(-Wl,--no-as-needed -ljemalloc -lnuma -pthread)
omp=(-fopenmp "-Wl,-rpath,${prefix}/lib")

# Run the deployed selection policy on the supplied sources, before adding probes.
"${CLANG}" "${ccflags[@]}" -emit-llvm -c "${btree}/btree/btree.c" -o "${OUT_DIR}/btree.bc"
"${CLANGXX}" "${cxxflags[@]}" -emit-llvm -c "${micro}/coherence_noise.cpp" -o "${OUT_DIR}/micro.bc"
for name in btree micro; do
  configure_hitm_seed_experiment "${name}"
  "${OPT}" -load-pass-plugin "${PLUGIN}" -passes="${REWRITE_PASS}" "${REWRITE_ARGS[@]}" \
    "${OUT_DIR}/${name}.bc" -o "${OUT_DIR}/${name}.auto.bc"
done

# Both matched controls and placement builds include the same post-timing checks.
patch --batch --forward --fuzz=0 -o "${OUT_DIR}/btree.c" "${btree}/btree/btree.c" "${adapters}/btree.patch"
patch --batch --forward --fuzz=0 -o "${OUT_DIR}/coherence_noise.cpp" "${micro}/coherence_noise.cpp" "${adapters}/coherence-noise.patch"
"${CLANG}" -O3 -march=native -fopenmp -DDISABLE_SIGNAL_IN_MAIN -c "${btree}/common/main-mt.c" -o "${OUT_DIR}/driver.o"
for mode in native placed; do
  extra=()
  if [[ "${selection}" == policy ]]; then
    if [[ "${mode}" == native ]]; then
      "${CLANG}" "${ccflags[@]}" -I"${adapters}" -emit-llvm -c "${OUT_DIR}/btree.c" -o "${OUT_DIR}/btree-native.bc"
    else
      configure_hitm_seed_experiment btree-native
      "${OPT}" -load-pass-plugin "${PLUGIN}" -passes="${REWRITE_PASS}" "${REWRITE_ARGS[@]}" \
        "${OUT_DIR}/btree-native.bc" -o "${OUT_DIR}/btree-placed.bc"
    fi
    "${CLANG}" -O3 -c "${OUT_DIR}/btree-${mode}.bc" -o "${OUT_DIR}/btree-${mode}.o"
  else
    if [[ "${mode}" == placed ]]; then extra+=(-DARBITER_BTREE_NODE_ARRAYS); fi
    "${CLANG}" "${ccflags[@]}" "${extra[@]}" -I"${adapters}" -I"${ROOT_DIR}/runtime/include" \
      -c "${OUT_DIR}/btree.c" -o "${OUT_DIR}/btree-${mode}.o"
  fi
  "${CLANGXX}" "${OUT_DIR}/driver.o" "${OUT_DIR}/btree-${mode}.o" "${runtime}" \
    "${omp[@]}" "${libs[@]}" -o "${OUT_DIR}/btree-${mode}"
done

"${CLANGXX}" "${cxxflags[@]}" -I"${adapters}" -emit-llvm -c "${OUT_DIR}/coherence_noise.cpp" -o "${OUT_DIR}/micro-native.bc"
"${OPT}" -load-pass-plugin "${PLUGIN}" -passes=arbiter-report-sites \
  -arbiter-report-path="${OUT_DIR}/micro-sites.csv" -disable-output "${OUT_DIR}/micro-native.bc"
# Resolve the entry-table allocation from this build's debug location. Ballast
# is a second new[] in the same function and must stay on the local node.
table_site="$(python3 - "${OUT_DIR}" <<'PY'
import csv
import sys
from pathlib import Path
out = Path(sys.argv[1])
source = out / "coherence_noise.cpp"
lines = {i for i, line in enumerate(source.read_text().splitlines(), 1)
         if "g_table = new Entry[" in line}
with (out / "micro-sites.csv").open() as stream:
    ids = [row["site_id"] for row in csv.DictReader(stream)
           if row["kind"] == "cxx-new-array" and Path(row["file"]).resolve() == source.resolve()
           and int(row["line"]) in lines]
if len(ids) != 1:
    sys.exit(f"expected exactly one entry table new[], found {ids}")
print(ids[0])
PY
)"
REWRITE_ARGS=(-arbiter-hitm-seed-site-ids="${table_site}")
if [[ "${selection}" == policy ]]; then
  configure_hitm_seed_experiment micro-native
fi
"${OPT}" -load-pass-plugin "${PLUGIN}" -passes=arbiter-experiment-hitm-seed-rewrite \
  "${REWRITE_ARGS[@]}" "${OUT_DIR}/micro-native.bc" -o "${OUT_DIR}/micro-placed.bc"
for mode in native placed; do
  "${CLANGXX}" "${cxxflags[@]}" "${OUT_DIR}/micro-${mode}.bc" "${runtime}" "${libs[@]}" -o "${OUT_DIR}/micro-${mode}"
done
python3 - "${OUT_DIR}" "${selection}" "${table_site}" <<'PY'
import csv
import json
import sys
from pathlib import Path
out = Path(sys.argv[1])
objects = {"btree": {"keys": 1, "pointers": 2}, "micro": {"table": int(sys.argv[3])}}
if sys.argv[2] == "policy":
    def selected(stem):
        with (out / f"{stem}.hitm-seed-sites.csv").open() as stream:
            return {int(row["site_id"]) for row in csv.DictReader(stream) if row["selected"] == "yes"}
    if selected("btree-native"):
        sys.exit("B-tree validation needs a page probe for the newly selected allocation")
    objects["btree"] = {}
    chosen = selected("micro-native")
    lines = (out / "coherence_noise.cpp").read_text().splitlines()
    with (out / "micro-sites.csv").open() as stream:
        ballast = [int(row["site_id"]) for row in csv.DictReader(stream)
                   if Path(row["file"]).resolve() == (out / "coherence_noise.cpp").resolve()
                   and "g_ballast = new uint64_t[" in lines[int(row["line"]) - 1]]
    if len(ballast) != 1:
        sys.exit(f"expected exactly one ballast new[], found {ballast}")
    known = {"table": int(sys.argv[3]), "ballast": ballast[0]}
    if chosen - set(known.values()):
        sys.exit("Microbenchmark validation needs a page probe for the newly selected allocation")
    objects["micro"] = {name: site for name, site in known.items() if site in chosen}
(out / "selected-objects.json").write_text(json.dumps(objects, indent=2) + "\n")
PY
sha256sum "${btree}/btree/btree.c" "${btree}/common/main-mt.c" "${micro}/coherence_noise.cpp" \
  "${ARBITER_HITM_SEED_CONFIG}" "${PLUGIN}" "${runtime}" "${OUT_DIR}/selected-objects.json" \
  "${OUT_DIR}"/{btree,micro}-{native,placed} >"${OUT_DIR}/inputs.sha256"
printf 'Built B-tree and coherence_noise in %s (%s selection)\n' "${OUT_DIR}" "${selection}"
