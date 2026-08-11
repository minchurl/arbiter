# Hot-Set Placement Experiment Results

This ledger records protected XIndex/YCSB hot-set comparisons. Generated files
under `build/` remain local; retain the input config, decision CSV, effective
arguments, and binary hashes with every durable result.

## 2026-08-12: 1M/4M CXL Safety and Tendency Pilot

This was a safety and tendency check, not a performance result. Codex and other
background workloads remained active, and each configuration ran once with one
YCSB iteration.

Run shape:

```sh
XINDEX_SCALE_LOAD_RECORDS=1000000 \
XINDEX_SCALE_TX_OPS=4000000 \
REPEATS=1 \
XINDEX_FG=16 \
XINDEX_ITERATION=1 \
XINDEX_DURATION_SECONDS=0 \
MEMORY_MAX=16G \
MEMORY_SWAP_MAX=0 \
ARBITER_CPU_NODE=0 \
ARBITER_MEM_NODE=0 \
ARBITER_TARGET_NODE=2 \
ARBITER_HEAP_BACKEND=direct \
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-sweep-base.config \
./scripts/run-protected-hotset-experiment.sh
```

The driver ran native, hot-set local, and hot-set target configurations. The
local and target rows used the same rewritten binary. Direct `numastat`
sampling confirmed that target pages were resident on the memory-only CXL NUMA
node 2.

### Sweep-Base Observation

`configs/hotset/xindex-sweep-base.config` selected three seeds and four
members. All four selected members already had the maximum write affinity of
5, so raising only `ARBITER_HOTSET_MEMBER_MIN_AFFINITY` would not reduce the
set.

At the 1M/4M scale:

| Metric | Value |
|---|---:|
| Hot-set local throughput | 21.28M op/s |
| Hot-set target throughput | 0.61-0.77M op/s |
| Target process maximum RSS | 5.33 GiB |
| Peak sampled CXL-node residency | 4751.89 MiB (4.64 GiB) |

The selected allocations are mostly 96-byte objects and 8-byte vector storage.
The runtime calls `numa_alloc_onnode` for each object, so every tiny allocation
can consume a page. Static selected-site count and static estimated bytes
therefore substantially understate runtime CXL footprint.

### Conservative `put` Pair

`configs/hotset/xindex-cxl-conservative.config` raises the seed threshold,
pins the score-14 `put` root (site 99 in this matching build), keeps one
fixed-size write member, rejects the dynamically sized member through a 1KiB
budget, and selects two sites total.

| Config | Throughput | Maximum RSS |
|---|---:|---:|
| Native | 40.79M op/s | 0.93 GiB |
| Hot-set local | 27.53M op/s | 0.95 GiB |
| Hot-set target | 0.443M op/s | 2.49 GiB |

A protected target recheck also completed successfully at 0.456M op/s. Peak
sampled CXL-node residency was 2025 MiB (1.98 GiB), a 57% reduction from the sweep-base
pilot. No swapping, OOM event, or kernel fault occurred.

This is a safer profile point, not a performance improvement. Targeting the
`put` allocation pair makes the workload substantially slower, and 2GiB of CXL
residency for 1M load records still demonstrates page-granularity amplification.
Do not extrapolate this config to the 100M-record full trace without either a
much lower scale limit or a pooled target allocator plus dynamic allocation and
live-byte profiling.

## 2026-08-12: Site-99 Slab/Arena Validation

This implementation validation used
`configs/hotset/xindex-cxl-arena.config`, which selects only the fixed 96-byte
`put` root. Local and CXL runs used the same 2MiB-slab allocator with 64-byte
minimum alignment, making each object occupy a 128-byte slot. The only runtime
difference was binding the arena to node 0 or node 2.

The allocator smoke test placed 20,000 objects into 625 resident 4KiB pages.
All queried pages were on node 0 for the local run and node 2 for the CXL run.
Both runs reported zero fallback allocations.

At the protected 1M-load/4M-transaction scale with 16 foreground threads and a
one-second time-based measured interval:

| Metric | Value |
|---|---:|
| Site-99 allocation calls | 357,388 |
| Peak live site-99 objects | 357,388 |
| Requested payload | 34,309,248 bytes (32.72MiB) |
| Rounded slot bytes | 45,745,664 bytes (43.63MiB) |
| Assigned slab capacity | 22 slabs, 44MiB |
| Actual resident arena pages | 11,169 pages, 45,748,224 bytes (43.63MiB) |
| Local / target page majority | node 0 / node 2, with zero query errors |
| Arena fallbacks | 0 |
| Swaps / OOM / kernel faults | 0 / 0 / 0 |

The legacy direct backend would require roughly 1.36GiB for the same number of
live site-99 objects if every 96-byte allocation consumed a 4KiB page. The
arena therefore removed the dominant page-granularity amplification and the
per-object side-table insertion. Maximum process RSS was about 0.99GiB local
and target, rather than the multi-GiB direct-placement result.

Native, local-arena, and CXL-arena throughput in this one run was 63.24M,
60.23M, and 47.27M op/s respectively. The duration stopped at
1.0004-1.0012 seconds, but one second and one repeat remain validation data,
not a performance conclusion. The driver defaults to 60 seconds for the later
quiet-system tendency run.

After stopping unrelated workloads, run that 60-second comparison with the
already-built binaries as follows. Use a new `RESULT_DIR` for every run; the
driver deliberately refuses to overwrite an existing result.

```sh
RESULT_DIR="$PWD/build/arbiter-bench/hotset-arena-1m-4m-60s-run1" \
XINDEX_SCALE_LOAD_RECORDS=1000000 \
XINDEX_SCALE_TX_OPS=4000000 \
XINDEX_DURATION_SECONDS=60 \
XINDEX_FG=16 \
REPEATS=1 \
ARBITER_CPU_NODE=0 \
ARBITER_MEM_NODE=0 \
ARBITER_TARGET_NODE=2 \
ARBITER_HEAP_BACKEND=arena \
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-cxl-arena.config \
MEMORY_MAX=16G \
MEMORY_SWAP_MAX=0 \
BUILD_BENCHMARKS=0 \
MKL_RUNTIME_DIR=/opt/intel/oneapi/mkl/2025.2/lib \
./scripts/run-protected-hotset-experiment.sh
```

This executes three measured rows—native, arena on node 0, and the same arena
on CXL node 2—so the measured portion is about three minutes plus data loading
and index construction.
