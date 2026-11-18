# Replacing the XIndex NUMA slab with jemalloc

On 2026-11-17 we compared the slab runtime at `d02fda2` with the jemalloc
runtime at `0adfc7c` on the same Xeon Gold 6548Y+ host. Both XIndex executables
already linked jemalloc for ordinary heap allocations. The runtime change
moves the **compiler-selected objects** to explicit jemalloc arenas backed by
the same bounded NUMA policy.

## Full XIndex YCSB-A replay

| Mean measurement | Custom slab | jemalloc 5.2.1 | Change |
|---|---:|---:|---:|
| Local DRAM throughput | 27.27 M tx/s | 27.36 M tx/s | +0.31% |
| CXL throughput | 45.05 M tx/s | 48.59 M tx/s | +7.86% |
| Resident arena, both placements | 17.31 GiB | 19.08 GiB | +10.21% |
| Peak process RSS, both placements | 30.20 GiB | 32.05 GiB | +6.14% |

Each process loaded 100 million records and executed all 400 million
transactions with 31 foreground workers and one background worker on node 0.
The ordinary heap stayed on node 0. Each run bound the selected objects to
either local DRAM (node 0) or CXL memory (node 2). Each process used a strict
24 GiB arena in a 64 GiB systemd scope with swap disabled. We ran four
local-then-CXL pairs in slab, jemalloc, jemalloc, slab order. Each throughput
change is the ratio of arithmetic means at the same placement.
[Individual measurements](../../results/xindex/ycsb-a/jemalloc-20261117/runs.csv)

The timed interval covers transactions after the index is built. Whole-process
elapsed time also includes trace input, index construction, validation and
residency reporting. The filesystem cache was left under normal kernel
management and the first slab process had a longer wall time. With two runs
per allocator and placement, small throughput changes are sensitive to run
order and host variation.

All eight runs executed the same operation count and returned the same
4,096-key digest, `0x7474b8e9d3962859`. Every queried resident arena page
was on the requested node. There were zero fallbacks, placement-query errors
and swaps. Both runtimes made 52,791,182 selected allocations at sites 68,
71 and 74. Site 68's 96-byte objects occupied 128 bytes with either allocator.
At sites 71 and 74, jemalloc rounded 520 bytes to 640 bytes, compared with 576
bytes in the slab. Across 26,395,765 such objects that accounts for 1.57 GiB
of the 1.77 GiB increase in resident arena memory.

## Allocation and release workload

| Median elapsed, five processes per cell | Custom slab | jemalloc 5.2.1 | Change |
|---|---:|---:|---:|
| Local DRAM | 1.36 s | 4.83 s | +255.55% |
| CXL | 1.86 s | 4.97 s | +167.63% |

The arena smoke executable allocated and touched two million 96-byte objects
from eight threads, checked the page locations and freed them from a second
set of threads. It then allocated, touched and freed the same population
serially. Elapsed time includes those operations, sorting page addresses,
thread creation and process startup. Both executables used the same test
source, CPU binding (0–7), 512 MiB reserve and ordinary heap on node 0.
Allocator and node order alternated between rounds.
[Individual timings](../../results/xindex/ycsb-a/jemalloc-20261117/arena-smoke.csv)

## Reproduction

Build `arbiter_runtime` in CMake Release mode with LLVM 18 for each revision.
Use the same compiler plugin, XIndex source, MKL installation, system jemalloc
and full YCSB-A traces for both. The XIndex bitcode after the allocation
rewrite had SHA-256
`874a18c747b452d48566dd61b750f3811edfd7868cefdb8c3a037210606fb59e`
in both builds. The executable hashes were
`aab9fb6d1cf3a5f79617463358d1954d8a13bfe541809d8f033e1d50d97b5e8a` (slab)
and `e94972432898885a4904acd571ea5bbe7fef478773e14a4705576d75695dffc7`
(jemalloc). Run one pair at a time in the order above with unique output
directories.

```sh
ARBITER_BUILD_DIR="$PWD/build-release" \
ARBITER_HITM_SEED_CONFIG="$PWD/configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config" \
  scripts/validate-xindex-runtime-correctness-full.sh
```

For the allocation workload, link the same smoke source against each release
archive. Both executables link ordinary allocations to the system jemalloc.
Run each executable in a fresh process with node 0 and node 2 in turn.

```sh
g++ -std=c++17 -O3 -pthread -Iruntime/include \
  tests/llvm/arbiter-slab-arena-smoke.cpp build-release/runtime/libarbiter_runtime.a \
  -ljemalloc -lnuma -o build-release/arena-timing
node=0
ARBITER_TEST_OBJECTS=2000000 ARBITER_TEST_THREADS=8 \
ARBITER_HEAP_BACKEND=arena ARBITER_ARENA_STRICT=1 \
ARBITER_ARENA_RESERVE_BYTES=536870912 ARBITER_TARGET_NODE="$node" \
ARBITER_EXPECT_NODE="$node" /usr/bin/time -f '%e %M' \
  numactl --physcpubind=0-7 --membind=0 build-release/arena-timing
```
