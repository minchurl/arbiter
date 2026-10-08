# Arbiter

Arbiter implements **heuristic-guided HITM-risk seed placement** for
coherence-sensitive XIndex objects on local or CXL-attached NUMA memory. The
current implementation is a single seed-only pipeline:

```text
XIndex C++ -> LLVM IR -> HITM-risk seed selection -> allocation rewrite
           -> fixed-size NUMA arena -> local/CXL comparison
```

The compiler score is a static proxy built from pointer escape,
synchronization, worker reachability, and allocation size. It does not consume
hardware HITM samples. The runtime performs allocation-time placement; it does
not migrate existing objects.

## Repository Map

- `compiler/llvm/lib/hitm_seed/`: seed scoring, options, report, and rewrite
- `runtime/src/arbiter_slab_arena.cpp`: NUMA-bound slab allocator
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
- Linux `libnuma`
- Intel MKL and jemalloc for XIndex
- `git-lfs` and `zstd` when restoring the packaged 46GB YCSB traces
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
binaries, creates smoke traces, and runs short local checks. The raw traces
need roughly 46GB of disk space. Use `--no-smoke` or `--no-data` only when the
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

## Run the XIndex Experiment

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

Across four one-pass pairs, `raw-046` averaged 26.531M local versus 49.068M
CXL op/s: **+85.03% mean paired improvement**. See
[the YCSB-A result](docs/results/xindex-ycsb-a.md) for pairwise results, safety
counters, and the earlier cyclic-replay history.

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
  build-llvm18/bin/arbiter-slab-arena-smoke 40000
```

## Documentation

- [Architecture and code map](docs/overview.md)
- [Seed selection and allocator reference](docs/hitm-risk-seed-placement.md)
- [Validated XIndex results](docs/results/README.md)
- [Benchmark data management](docs/benchmark-data.md)
