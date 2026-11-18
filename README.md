# Arbiter

Arbiter implements **heuristic-guided HITM-risk seed placement** for
coherence-sensitive XIndex objects on local or CXL-attached NUMA memory. The
current implementation is a single seed-only pipeline:

```text
XIndex C++ -> LLVM IR -> HITM-risk seed selection -> allocation rewrite
           -> NUMA-bound jemalloc arenas -> local/CXL comparison
```

The compiler score is a static proxy built from pointer escape,
synchronization, worker reachability, and allocation size. It does not consume
hardware HITM samples. The runtime performs allocation-time placement; it does
not migrate existing objects.

## Repository Map

- `compiler/llvm/lib/hitm_seed/`: seed scoring, options, report, and rewrite
- `runtime/src/arbiter_jemalloc_arena.cpp`: jemalloc arenas and NUMA extent hooks
- `runtime/src/arbiter_runtime_site.cpp`: rewritten allocation ABI
- `configs/hitm-seed/candidates/`: curated top 12 measured seed policies
- `scripts/run-xindex-hitm-seed-replay.sh`: canonical full-scale one-pass runner
- `scripts/run-protected-hitm-seed-experiment.sh`: lower-level experiment driver
- `docs/overview.md`: architecture and code-reading guide
- `docs/hitm-risk-seed-placement.md`: policy and runtime reference
- `docs/results/`: current XIndex/YCSB results and claim boundaries
- `results/xindex/`: retained machine-readable evidence

Generic allocation rewriting and the GUPS smoke path remain as infrastructure.
The unused MLIR, shared-mutable, lock-touch, and broad-search executables were
removed from the active tree. Historical methods are separated under
`docs/history/`; reusable search inputs and reportable measurements remain
checked in under `configs/` and `results/`.

## Requirements

- CMake 3.20+, Ninja, and a C++17 compiler
- LLVM 18 development files and tools (`clang`, `opt`, `llvm-link`)
- Linux `libnuma` and jemalloc 5 development files for the NUMA arena
- Intel MKL for XIndex
- `git-lfs` and `zstd` when restoring the packaged 26GB YCSB-A traces
- systemd user scopes for the protected 64G benchmark limit

Ubuntu packages:

```sh
sudo apt install cmake ninja-build make gcc clang-18 llvm-18-dev \
  libnuma-dev libjemalloc-dev git-lfs zstd numactl
```

MKL defaults to `/opt/intel/oneapi/mkl/latest`. Override
`MKL_INCLUDE_DIR`, `MKL_LINK_DIR`, and `MKL_RUNTIME_DIR` when needed.

## Fresh Setup

```sh
git lfs install
./scripts/setup-benchmarks.sh
```

This restores the full traces, builds the LLVM plugin/runtime and benchmark
binaries, creates smoke traces, and runs short local checks. The active raw traces
need roughly 26GB of disk space. Use `--no-smoke` or `--no-data` only when the
corresponding artifacts already exist.

Manual compiler/runtime build:

```sh
cmake -S . -B build-llvm18 -G Ninja \
  -DCMAKE_C_COMPILER=/usr/lib/llvm-18/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/lib/llvm-18/bin/clang++
cmake --build build-llvm18 --target \
  ArbiterLLVMPlugin arbiter_runtime arbiter-runtime-smoke \
  arbiter-slab-arena-smoke
```

## Run B-tree and the coherence microbenchmark

Use the compiler/runtime build above on a host with local DRAM and a CXL
memory node. For the measured configuration, add `-DCMAKE_BUILD_TYPE=Release`
when configuring CMake. These workloads also need Clang's OpenMP development package
(`libomp-18-dev` on Ubuntu), `patch`, GNU time, and Python 3.9+.

```sh
./scripts/build-btree-coherence.sh
./scripts/run-btree-coherence.py
```

The build reads the supplied sources from `~/vmitosis-workloads` and
`~/microbench`. Set `VMITOSIS_DIR`, `MICROBENCH_DIR`, or `ARBITER_BUILD_DIR`
to use different locations. It applies the published-RMW selection policy
to the patched copies and builds matched native and automatically selected binaries.

The runner uses 32 workers and three rounds of native, selected-local, and
selected-CXL placement. CPU and local memory default to node 0 and CXL to
node 2. Use `--cpu-node`, `--local-node`, and `--cxl-node` on a different
topology, or `--benchmark btree` / `--benchmark micro` to run just one workload.
Each run records throughput, peak RSS and live page locations under
`build/arbiter-bench/`. See the [results and methodology](docs/results/btree-coherence.md).

The published-RMW policy distinguishes the shared table from its read-only
ballast. `ARBITER_HITM_SEED_CONFIG` overrides the policy; the build manifest
records the automatically selected objects, including zero selections.
See the [policy evaluation](docs/results/published-rmw-policy.md).

The microbenchmark adapter now validates writes and fixes the supplied
100%-read threshold, lock ownership and non-atomic shared accesses. It also
publishes each single-writer epoch with an atomic store. Set
`ARBITER_MICRO_EPOCH_STORE=0` when building for the corrected locked-increment
control. These changes apply to the build copy; the supplied source is untouched.

The runner accepts `--read-pct`, `--table-size`, `--ballast-mb`, `--victims`,
`--noise`, and `--noise-mode`. For example, a 90%-write workload is:

```sh
./scripts/run-btree-coherence.py --benchmark micro --read-pct 10 \
  --modes local cxl --rounds 3 --duration 30
```

To compare a cache-line-sized entry layout, build separately with
`ARBITER_MICRO_ENTRY_BYTES=64`. The default remains 32 bytes to retain the
original adjacent-entry false sharing. Both layouts select the same table
allocation and keep ballast local. The 64-byte experiment verifies table
alignment at runtime. Larger tables may require `--arena-chunk-bytes` of at
least twice the allocation size, rounded up to a power of two.
The throughput preset below enables padding and epoch stores.

```sh
. configs/benchmarks/coherence-throughput.config
./scripts/build-btree-coherence.sh
./scripts/run-btree-coherence.py --benchmark micro --modes local cxl \
  --bin-dir "$ARBITER_BENCH_BUILD_DIR"
python3 scripts/test-coherence-adapter.py "$ARBITER_BENCH_BUILD_DIR"
```

Use `--perf /path/to/perf` on a microbenchmark run to count cycles,
instructions, L3 HitM loads, L3 misses and locked loads only during the
measurement window. This event list targets the measured Intel host.
See the [microbenchmark tuning results](docs/results/coherence-tuning.md)
for the allocation analysis, measured gains, full cases and reproduction.

## Run the XIndex Experiment

For the meeting demo, run A or F independently:

```sh
./scripts/run-xindex-a-demo.sh   # A: read 50% / update 50%
./scripts/run-xindex-f-demo.sh   # F: read 50% / RMW 50%
```

Each script is linear: set the workload/policy, build, run **Local once then CXL
once**, and print both throughputs and the percentage change to the console.
Native is excluded. Every process builds the index from 100M load records and
finishes all 400M transactions; there is no duration cutoff or cyclic replay.
The automatic evidence-balanced policy, 31+1 workers, 64G memory limit, and
post-timing validation are shared. The demo scripts take no arguments.
F uses A's trace with UPDATE interpreted as RMW. Each RMW counts as one logical
transaction, so A and F do not perform the same number of index API calls.
The [2026-10-22 demo results](results/xindex/af-demo-20261022-1447/README.md)
retain the measured A/F pairs and their raw logs.

For the automatic policy with size reduced to a +1 tie breaker:

```sh
./scripts/run-xindex-evidence-balanced.sh   # A: read/update
./scripts/run-xindex-ycsb-f.sh              # F: read/read-modify-write
```

The F runner compares native, selected-Local, and selected-CXL with correctness
checks and one full trace pass per process. `--smoke` checks short traces first;
`--check` only checks the full-run settings. F reuses A's input keys and maps
each UPDATE to a same-worker get followed by put, counted as one logical
transaction. It needs no additional full trace. Use `REPEATS=4` for four rounds.
See [the F protocol](docs/xindex-ycsb-f.md). B's results are
[archived](docs/results/xindex-ycsb-b.md); B is no longer an active workload.

First verify the machine and full traces without starting a benchmark:

```sh
ARBITER_TARGET_NODE=2 ./scripts/run-xindex-hitm-seed-replay.sh --check
```

Run one complete 400M-operation trace for each side of one local/CXL pair:

```sh
ARBITER_TARGET_NODE=2 ./scripts/run-xindex-hitm-seed-replay.sh --quick
```

`--quick` changes only the pair count from four to one. Every row consumes the
transaction trace exactly once and exits; there is no duration cutoff and no
cyclic trace replay. For the stronger four-pair confirmation, start the default
command in tmux:

```sh
tmux new-session -d -s arbiter-hitm-seed -c "$(pwd)" \
  'ARBITER_TARGET_NODE=2 ./scripts/run-xindex-hitm-seed-replay.sh \
   > build/arbiter-bench/xindex-hitm-seed-replay.console.log 2>&1'
tmux attach -t arbiter-hitm-seed
```

The wrapper uses `raw-046`, 100M load records, the 400M-operation YCSB-A
trace, 31 foreground plus one background worker, four alternating one-pass
local/CXL pairs, strict 24GiB arenas, `MemoryMax=64G`, and no swap.

Results are written to a unique timestamped directory under
`build/arbiter-bench/`. Each completed run now writes `interpretation.md`,
which reports paired throughput, all statically selected sites, sites that
actually allocated objects, CXL resident bytes, NUMA placement, fallbacks,
swaps, and row status. To interpret the newest replay or a specific result:

```sh
./scripts/summarize-xindex-hitm-seed-result.sh
./scripts/summarize-xindex-hitm-seed-result.sh \
  build/arbiter-bench/xindex-hitm-seed-replay-YYYYMMDD-HHMMSS
```

The canonical `raw-046` selection is automatic: sites
`68+71+74+90+97+98+99+100` are rewritten, while only `68+71+74` allocate in
the current YCSB-A trace. The report keeps this static-selection/runtime-use
distinction explicit; no site ID is pinned in the config.

With the original slab allocator, four one-pass pairs of `raw-046` averaged
26.531M local versus 49.068M CXL op/s for a **+85.03% mean paired improvement**. See
[the YCSB-A result](docs/results/xindex-ycsb-a.md) for pairwise results, safety
counters, and the earlier cyclic-replay history. Both runtimes were also compared on the
same host for throughput, memory use and allocation time. [Jemalloc comparison](docs/results/xindex-jemalloc.md)

## Build Another Retained Policy

```sh
ARBITER_HITM_SEED_CONFIG=configs/hitm-seed/candidates/raw-082.config \
  ./scripts/build-xindex-llvm.sh
```

The 12 retained policies and their measured runtime fingerprints are listed in
[the config index](configs/hitm-seed/README.md). `raw-046.config` is the default.

## Tests

```sh
cmake --build build-llvm18
ARBITER_BUILD_DIR=build-llvm18 ./scripts/smoke.sh
build-llvm18/bin/arbiter-runtime-smoke
ARBITER_HEAP_BACKEND=arena ARBITER_TARGET_NODE=0 \
  ARBITER_ARENA_STRICT=1 ARBITER_ARENA_REPORT=1 \
  ARBITER_TEST_OBJECTS=40000 build-llvm18/bin/arbiter-slab-arena-smoke
```

## Documentation

- [Architecture and code map](docs/overview.md)
- [Seed selection and allocator reference](docs/hitm-risk-seed-placement.md)
- [Validated XIndex results](docs/results/README.md)
- [Benchmark data management](docs/benchmark-data.md)
