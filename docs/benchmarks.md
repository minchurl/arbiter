# Benchmarks

This document tracks benchmark targets for Arbiter.

## Status

| Benchmark | Status | Purpose |
| --- | --- | --- |
| GUPS | In progress | First placement-sensitivity benchmark |
| XIndex + YCSB | Planned | Application-level coherence-sensitive workload |

## GUPS

GUPS means giga updates per second. HPCC RandomAccess is the common benchmark
for this metric.

Core operation:

```text
table[random_index] ^= random_value
```

Arbiter uses GUPS first because it gives a small benchmark for testing whether
placing one large allocation on another memory node changes performance.

The benchmark can also apply hot/cold skew. For example,
`--hot-region-percent 10 --hot-access-percent 90` sends 90% of updates to the
first 10% of the table.

### Current Setup

Source:

```text
benchmarks/gups/gups.cpp
```

Build flow:

```text
gups.cpp -> cgeist -> MLIR -> arbiter-opt -> mlir-translate -> clang++
```

The build creates:

- `build-llvm18/benchmarks/gups/gups-system`
- `build-llvm18/benchmarks/gups/gups-arbiter`

`gups-system` uses the normal frontend/lowering path. `gups-arbiter` runs the
Arbiter passes so the frontend-visible table allocation is lowered to
`arbiter_alloc`.

### Build

```sh
cmake --build build-llvm18 --target gups-pipeline
```

Requires `cgeist`, `mlir-opt`, `mlir-translate`, `clang++`, and the Arbiter
runtime library.

### Run

There are three common ways to run the benchmark.

Single run for quick checks:

```sh
build-llvm18/benchmarks/gups/gups-system \
  --mode system \
  --table-mib 1024 \
  --hot-region-percent 10 \
  --hot-access-percent 90 \
  --updates 536870912

ARBITER_TARGET_NODE=1 \
  build-llvm18/benchmarks/gups/gups-arbiter \
    --mode arbiter \
    --table-mib 1024 \
    --hot-region-percent 10 \
    --hot-access-percent 90 \
    --updates 536870912
```

CSV runner for repeated system-vs-Arbiter measurements:

```sh
TABLE_MIB=1024 HOT_REGION_PERCENT=10 HOT_ACCESS_PERCENT=90 \
  UPDATES=536870912 REPEATS=3 \
  scripts/run_gups_bench.sh
```

Remote NUMA run with explicit CPU and memory policy:

```sh
numactl --cpunodebind=0 --membind=0 \
  build-llvm18/benchmarks/gups/gups-system \
    --mode system \
    --table-mib 1024 \
    --hot-region-percent 10 \
    --hot-access-percent 90 \
    --updates 536870912

numactl --cpunodebind=0 --membind='!1' \
  env ARBITER_TARGET_NODE=1 \
  build-llvm18/benchmarks/gups/gups-arbiter \
    --mode arbiter \
    --table-mib 1024 \
    --hot-region-percent 10 \
    --hot-access-percent 90 \
    --updates 536870912
```

### Output

Important fields:

- `gups`: updates per second divided by `1e9`
- `ns_per_update`: elapsed nanoseconds per update
- `mode`: `system` or `arbiter`
- `actual_table_mib`: actual power-of-two table size
- `hot_region_percent`: percent of the table treated as hot
- `hot_entries`: number of table entries in the hot region
- `hot_access_percent`: percent of updates targeting the hot region
- `arbiter_target_node`: target node used by Arbiter, if set

Timing excludes allocation and table initialization.

## XIndex + YCSB

Status: planned.

Motivation from prior observations:

- YCSB-A is write-heavy and showed performance improvement when some data was
  placed on CXL-like memory.
- YCSB-B is read-mostly and showed little or no improvement.
- This suggests the effect may be related to coherence overhead, not only raw
  memory latency.

Target comparison:

- YCSB-A: coherence-sensitive candidate
- YCSB-B: read-mostly contrast case

Initial integration work should identify XIndex allocations for shared metadata
or shared writable cache lines before adding Arbiter placement.
