#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$PWD"
OUT_BASE="$PWD/build/libcuckoo-rmw"
SOURCE_DIR="$PWD/benchmark/libcuckoo/libcuckoo-upstream"
. build/jemalloc-comparison/tool-env
export LIBRARY_PATH="$PWD/.tools/libllvm18-root/usr/lib/x86_64-linux-gnu:$LIBRARY_PATH"
OPT="$PWD/.tools/llvm18-apt-root/usr/bin/opt-18"
CLANGXX="$PWD/.tools/llvm-18.1.8/bin/clang++"
PLUGIN="$OUT_BASE/compiler/lib/ArbiterLLVMPlugin.so"
ARBITER_HITM_SEED_CONFIG="$PWD/configs/hitm-seed/policy-candidates/published-rmw-size-tiebreaker.config"
source scripts/xindex-experiments/hitm-seed.sh
for variant in padded pause ttas ttas-padded; do
  OUT_DIR="$OUT_BASE/variant-$variant"
  mkdir -p "$OUT_DIR/include"
  cp -a "$SOURCE_DIR/libcuckoo" "$OUT_DIR/include/"
  python3 - "$OUT_DIR/include/libcuckoo" "$variant" <<'PY'
import sys
from pathlib import Path
p=Path(sys.argv[1]);v=sys.argv[2]
if 'padded' in v:
 f=p/'bucket_container.hh';s=f.read_text();assert s.count('class bucket {')==1;s=s.replace('class bucket {','class alignas(64) bucket {');f.write_text(s)
if v=='pause':
 f=p/'cuckoohash_map.hh';s=f.read_text();old='while (lock_.test_and_set(std::memory_order_acquire))\n        ;';assert old in s;s=s.replace(old,'while (lock_.test_and_set(std::memory_order_acquire))\n        __builtin_ia32_pause();');f.write_text(s)
if 'ttas' in v:
 f=p/'cuckoohash_map.hh';s=f.read_text();old='while (lock_.test_and_set(std::memory_order_acquire))\n        ;';assert old in s
 s=s.replace(old,'while (lock_.exchange(true, std::memory_order_acquire)) {\n        while (lock_.load(std::memory_order_relaxed))\n          __builtin_ia32_pause();\n      }')
 s=s.replace('lock_.test_and_set(std::memory_order_acquire)','lock_.exchange(true, std::memory_order_acquire)').replace('lock_.clear(std::memory_order_release)','lock_.store(false, std::memory_order_release)').replace('lock_.clear()','lock_.store(false, std::memory_order_relaxed)').replace('std::atomic_flag lock_;','std::atomic<bool> lock_;');f.write_text(s)
PY
  flags=(-std=c++17 -O2 -gline-tables-only -march=native -pthread --gcc-install-dir="$(dirname "$(gcc -print-libgcc-file-name)")")
  "$CLANGXX" "${flags[@]}" -I"$OUT_DIR/include" -I"$SOURCE_DIR" -emit-llvm -c benchmark/libcuckoo/contention.cpp -o "$OUT_DIR/contention.bc"
  configure_hitm_seed_experiment contention
  "$OPT" -load-pass-plugin "$PLUGIN" -passes="$REWRITE_PASS" "${REWRITE_ARGS[@]}" "$OUT_DIR/contention.bc" -o "$OUT_DIR/contention-placed.bc"
  for mode in native placed; do
    bc="$OUT_DIR/contention.bc"; [[ "$mode" == placed ]] && bc="$OUT_DIR/contention-placed.bc"
    "$CLANGXX" "${flags[@]}" "$bc" "$OUT_BASE/compiler/runtime/libarbiter_runtime.a" -Wl,--no-as-needed -ljemalloc -lnuma -o "$OUT_DIR/contention-$mode"
  done
  diff -u "$SOURCE_DIR/libcuckoo/bucket_container.hh" "$OUT_DIR/include/libcuckoo/bucket_container.hh" > "$OUT_DIR/bucket.patch" || [[ $? == 1 ]]
  diff -u "$SOURCE_DIR/libcuckoo/cuckoohash_map.hh" "$OUT_DIR/include/libcuckoo/cuckoohash_map.hh" > "$OUT_DIR/lock.patch" || [[ $? == 1 ]]
  sha256sum "$OUT_DIR"/contention-native "$OUT_DIR"/contention-placed "$OUT_DIR"/bucket.patch "$OUT_DIR"/lock.patch > "$OUT_DIR/inputs.sha256"
  echo "BUILT $variant"
done
