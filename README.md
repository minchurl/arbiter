# Arbiter

Arbiter is a compiler-assisted placement system for coherence-sensitive
memory objects in tiered memory environments.

The current benchmark workflow is LLVM-only: C/C++ benchmarks are lowered to
LLVM IR, an Arbiter LLVM pass plugin reports and rewrites selected allocation
sites, and the runtime places selected objects on a configured target memory
node such as remote NUMA memory or CXL-like memory.

The earlier MLIR/memref path is retained as a legacy precision/reference path,
but it is not used by the current LLVM-only benchmark workflow. See
[MLIR Legacy Path](docs/mlir-legacy.md).

## Current Pipeline

```text
C/C++ benchmark
  -> clang/clang++ LLVM IR
  -> opt -load-pass-plugin ArbiterLLVMPlugin
  -> linked binary with Arbiter runtime
  -> run with ARBITER_TARGET_NODE
```

The benchmark workflow uses one experiment pass:

```text
report-sites -> experiment-all-rewrite
```

`report-sites` does not modify IR. `experiment-all-rewrite` rewrites every
supported heap and anonymous mmap site, then rewrites the matching free/delete
and munmap sites to side-table-aware runtime calls.

## Build

Arbiter builds against LLVM 18 by default. The legacy MLIR path is optional.

Required:

- CMake 3.20 or newer
- Ninja
- C++17 compiler, such as `clang++`
- LLVM 18 development packages
- `opt`, `llvm-link`, and `FileCheck` for LLVM pass checks
- `libnuma-dev` on Linux for target-node placement
- `git-lfs` and `zstd` for the packaged XIndex/YCSB traces
- `jemalloc` and Intel MKL for XIndex
- MLIR 18 development packages only when building `mlir-legacy`

On Ubuntu 24.04:

```sh
sudo apt install cmake ninja-build make gcc clang-18 llvm-18-dev \
  libnuma-dev git-lfs zstd libjemalloc-dev
```

Install Intel MKL separately, or set `MKL_INCLUDE_DIR`, `MKL_LINK_DIR`, and
`MKL_RUNTIME_DIR` when building/running XIndex.

## Fresh Clone Benchmark Setup

For a fresh clone of the benchmark branch, use the one-shot setup:

```sh
git clone --branch experiment/generic-shared-mutable-placement \
  git@github.com:minchurl/arbiter.git
cd arbiter
./scripts/setup-benchmarks.sh
```

This script:

- pulls Git LFS chunks for the packaged XIndex/YCSB traces
- restores the full raw `.dat` files under `benchmark/xindex/YCSB/xindex_dat`
- configures and builds the Arbiter LLVM plugin/runtime in `build-llvm18`
- builds GUPS native and Arbiter variants
- builds XIndex native and Arbiter variants
- creates short XIndex/YCSB smoke traces from the full data
- runs short native/local smoke checks for both GUPS and XIndex/YCSB

The setup restores about 46GB of raw XIndex/YCSB trace data, so make sure the
machine has enough disk space. To skip the smoke checks:

```sh
./scripts/setup-benchmarks.sh --no-smoke
```

Configure and build:

```sh
cmake -S . -B build-llvm18 -G Ninja \
  -DCMAKE_C_COMPILER=/usr/lib/llvm-18/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/lib/llvm-18/bin/clang++

cmake --build build-llvm18 --target \
  ArbiterLLVMPlugin \
  arbiter_runtime \
  arbiter-runtime-smoke
```

## Runtime Placement

Selected LLVM allocation sites lower to runtime calls such as:

```c
arbiter_alloc_site(size, align, site_id, flags);
arbiter_calloc_site(count, elem_size, align, site_id, flags);
arbiter_mmap_site(size, prot, mmap_flags, site_id, flags);
```

The runtime tracks selected allocations in an internal side table so rewritten
deallocation calls can safely handle both Arbiter-managed and ordinary
allocations:

```c
arbiter_free_maybe(ptr);
arbiter_cxx_delete_maybe(ptr);
arbiter_cxx_delete_array_maybe(ptr);
arbiter_munmap_maybe(ptr, size);
```

The LLVM site-aware runtime does not call the header-based MLIR
`arbiter_alloc` ABI. It allocates from the selected backend directly and uses
the side table as the source of truth for `*_maybe` deallocation.
Heap-site alignment is not enforced in this first LLVM path; the `align`
argument is reserved for future aligned allocation support.

Set the target memory node with `ARBITER_TARGET_NODE`.

```sh
numactl --membind='!x' \
  env ARBITER_TARGET_NODE=x \
  ./program
```

If `ARBITER_TARGET_NODE` is unset or node allocation is unavailable, the
runtime falls back to host allocation for local checks.

## Benchmark Workflow

The recommended fresh-clone path is:

```sh
./scripts/setup-benchmarks.sh
```

If you already have a local Niagara workload checkout, import the full
XIndex/YCSB traces from it:

```sh
./scripts/import-niagara-workloads.sh --mode copy
```

For GitHub-friendly storage of the large traces, install Git LFS and package
the imported data into compressed chunks:

```sh
git lfs install
./scripts/package-xindex-ycsb-data.sh
```

Fresh clones can restore the raw `.dat` files with:

```sh
git lfs pull
./scripts/restore-xindex-ycsb-data.sh
```

Create short smoke traces from the full data:

```sh
./scripts/prepare-xindex-ycsb-smoke-data.sh
```

Collect allocation and mmap sites:

```sh
./scripts/collect-allocation-sites.sh path/to/input.bc
```

Build benchmark variants:

```sh
./scripts/build-gups-llvm.sh
./scripts/build-xindex-llvm.sh
```

Run native, instrumented-local, and instrumented-remote configurations:

```sh
./scripts/run-gups-arbiter.sh native
./scripts/run-gups-arbiter.sh local
ARBITER_TARGET_NODE=<node> ./scripts/run-gups-arbiter.sh remote

./scripts/run-xindex-arbiter.sh native
./scripts/run-xindex-arbiter.sh local
ARBITER_TARGET_NODE=<node> ./scripts/run-xindex-arbiter.sh remote
```

The first supported benchmarks are:

- GUPS: primary data region is anonymous `mmap`, so mmap rewriting is required.
- XIndex/YCSB: primary index structures are C++ heap objects, so C++ allocation
  ABI rewriting is required.

## Generic Placement Experiment

After `./scripts/setup-benchmarks.sh`, run the generic placement experiment from
the repository root in a separate tmux session:

```sh
tmux new-session -d -s arbiter-generic-exp -c "$(pwd)" \
  'mkdir -p build/arbiter-bench/generic-placement-experiment && REPEATS=3 ./scripts/run-generic-placement-experiment.sh 2>&1 | tee build/arbiter-bench/generic-placement-experiment/driver.log'
tmux attach -t arbiter-generic-exp
```

Results are written under:

```text
build/arbiter-bench/generic-placement-experiment
```

The main files are `runs.csv`, `summary.csv`, and `summary.md`. See
[Generic Placement Experiment](docs/generic-placement-experiment.md).

## MLIR Legacy Path

The MLIR tool remains available for memref-level experiments when explicitly
enabled:

```sh
cmake -S . -B build-llvm18-mlir -G Ninja \
  -DCMAKE_C_COMPILER=/usr/lib/llvm-18/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/lib/llvm-18/bin/clang++ \
  -DARBITER_ENABLE_MLIR_LEGACY=ON \
  -DMLIR_DIR=/usr/lib/llvm-18/lib/cmake/mlir

cmake --build build-llvm18-mlir --target arbiter-opt arbiter_runtime_mlir_legacy
ARBITER_BUILD_DIR=build-llvm18-mlir ./scripts/smoke-mlir-legacy.sh
```

This path is useful for precise object-boundary analysis, but it is not the
main benchmark path.

## Docs

- [Overview](docs/overview.md)
- [LLVM-Only Design](docs/llvm-only-design.md)
- [Benchmark Plan](docs/benchmark-plan.md)
- [Benchmark Data](docs/benchmark-data.md)
- [Generic Placement Experiment](docs/generic-placement-experiment.md)
- [Shared-Mutable Pattern Placement](docs/shared-mutable-pattern-placement.md)
- [MLIR Legacy Path](docs/mlir-legacy.md)
