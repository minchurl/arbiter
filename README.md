# Arbiter

Arbiter is a compiler-assisted placement system for coherence-sensitive
memory objects in tiered memory environments.

The current benchmark workflow is LLVM-only. The hot-set experiment scores
allocation sites, follows bounded seed-relative access paths, and applies a
configurable read/write-affinity boundary before rewriting selected calls to
the Arbiter runtime ABI.

The earlier MLIR/memref path is retained as a legacy precision/reference path,
but it is not used by the current LLVM-only benchmark workflow. See
[MLIR Legacy Path](docs/mlir-legacy.md).

## Current Pipeline

```text
C/C++ benchmark + hot-set config
  -> clang/clang++ LLVM IR
  -> arbiter-report-hotset-sites
  -> arbiter-experiment-hotset-rewrite
  -> selected calls rewritten to the Arbiter runtime ABI
  -> linked binary with Arbiter runtime
```

The current pass pair is:

```text
arbiter-report-hotset-sites -> arbiter-experiment-hotset-rewrite
```

The report records seed, member, and rejected decisions without changing IR.
The rewrite pass repeats the deterministic selection and rewrites only the
selected hot set. The all-site, shared-mutable, and lock-touch experiments
remain available as independent baselines. See
[Access-Affinity Hot Set Placement](docs/hotset-migration.md) for the policy and
config reference.

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
git clone --branch experiment/hotset-migration \
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
  arbiter-runtime-smoke \
  arbiter-slab-arena-smoke
```

## Runtime Placement

Selected LLVM allocation sites lower to runtime calls such as:

```c
arbiter_alloc_site(size, align, site_id, reserved);
arbiter_calloc_site(count, elem_size, align, site_id, reserved);
arbiter_mmap_site(size, prot, mmap_flags, site_id, reserved);
```

The existing ABI is unchanged; its final `uint32_t` slot is reserved and
rewriters pass zero. The runtime uses `ARBITER_TARGET_NODE` as the single
target-node setting. With the direct backend, leave it unset for a host
baseline and set it for a remote run. Arena comparisons set it explicitly to
the local or remote node; both rows still use the same rewritten binary.

The default `direct` heap backend tracks selected allocations in an internal
side table so rewritten deallocation calls can safely handle both
Arbiter-managed and ordinary allocations:

```c
arbiter_free_maybe(ptr);
arbiter_cxx_delete_maybe(ptr);
arbiter_cxx_delete_array_maybe(ptr);
arbiter_munmap_maybe(ptr, size);
```

The optional `arena` heap backend instead packs a fixed-size site's objects
into NUMA-bound slabs. A reserved virtual-address range identifies arena
pointers during `free`/`delete`, so strict arena runs need neither a
per-object side-table entry nor a per-object `numa_alloc_onnode` call. The
arena honors the greater of the requested alignment and its configured slot
alignment.

```sh
ARBITER_HEAP_BACKEND=arena \
ARBITER_TARGET_NODE=2 \
ARBITER_ARENA_SLAB_BYTES=2097152 \
ARBITER_ARENA_RESERVE_BYTES=4294967296 \
ARBITER_ARENA_SLOT_ALIGNMENT=64 \
ARBITER_ARENA_STRICT=1 \
ARBITER_ARENA_REPORT=1 \
./program
```

`ARBITER_TARGET_NODE` is required in arena mode, including a local comparison;
use node 0 for the local arena and the memory-only CXL node for the target
arena. `ARBITER_ARENA_RESERVE_BYTES` is an uncommitted virtual reservation and
a hard arena capacity, not immediate RSS. Strict mode fails instead of falling
back to the direct side-table path. A selected site must keep one fixed size
and requested alignment within a run; unsupported or changing shapes fail in
strict mode and are reported in non-strict mode. With reporting enabled, the
runtime also queries resident arena pages and their actual NUMA nodes at exit.

Hot-set selection is configured at build time:

```sh
ARBITER_XINDEX_EXPERIMENT=hotset \
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-sweep-base.config \
./scripts/build-xindex-llvm.sh
```

The target memory node is configured at runtime with `ARBITER_TARGET_NODE` for
hot-set and generic experiments alike.

```sh
numactl --membind='!x' \
  env ARBITER_TARGET_NODE=x \
  ./program
```

With the direct backend, an unset `ARBITER_TARGET_NODE` uses host allocation
and an unavailable node allocation falls back to it. Strict arena mode instead
requires a valid explicit node and fails closed on an unavailable or exhausted
arena.

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

Build the generic GUPS variant and the configured XIndex hot-set variant:

```sh
./scripts/build-gups-llvm.sh
ARBITER_XINDEX_EXPERIMENT=hotset \
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-sweep-base.config \
./scripts/build-xindex-llvm.sh
```

For a protected scaled hot-set comparison, use the dedicated driver. It builds
one configured binary, runs that same binary with local and target placement,
and retains the input config, decision CSV, effective `opt` arguments, binary
hashes, per-run resource usage, and summaries:

```sh
ARBITER_TARGET_NODE=<cxl-node> \
./scripts/run-protected-hotset-experiment.sh
```

The driver defaults to the site-99-only policy in
`configs/hotset/xindex-cxl-arena.config`, the slab backend, 100,000 load
records, 400,000 transactions, a 60-second measured interval per row, one
repeat, a 4GiB arena capacity, a 16GB memory limit, and no swap. The local and
target rows use the same arena implementation bound to node 0 and the requested
CXL node respectively. Set `XINDEX_DURATION_SECONDS=0` to use the legacy
`XINDEX_ITERATION` mode. Increase scale only after inspecting `runs.csv`,
`summary.md`, `hotset-sites.csv`, and the `arbiter-arena-summary` log line.

The following run-script modes remain the generic placement baseline:

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

For the first XIndex/YCSB remote-placement run, prefer the protected scaled
experiment. It creates smaller canonical trace files from the full data and runs
inside a user systemd memory scope so an OOM does not take unrelated services
with it:

```sh
tmux new-session -d -s arbiter-scale-exp -c "$(pwd)" \
  './scripts/run-protected-scaled-xindex-experiment.sh 2>&1 | tee build/arbiter-bench/generic-placement-scale-100000-400000/driver.log'
tmux attach -t arbiter-scale-exp
```

Useful scaling knobs:

```sh
XINDEX_SCALE_LOAD_RECORDS=1000000 \
XINDEX_SCALE_TX_OPS=4000000 \
MEMORY_MAX=96G \
REPEATS=3 \
./scripts/run-protected-scaled-xindex-experiment.sh
```

The protected scaled run writes `runs.csv`, `summary.csv`, `summary.md`, and
`report.md` under `build/arbiter-bench/generic-placement-scale-<load>-<tx>`.

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
- [Access-Affinity Hot Set Placement](docs/hotset-migration.md)
- [LLVM-Only Design](docs/llvm-only-design.md)
- [Benchmark Plan](docs/benchmark-plan.md)
- [Benchmark Data](docs/benchmark-data.md)
- [Generic Placement Experiment](docs/generic-placement-experiment.md)
- [Experiment Results](docs/experiments/README.md)
- [Shared-Mutable Pattern Placement](docs/shared-mutable-pattern-placement.md)
- [Lock-Touch Page Migration](docs/lock-touch-page-migration.md)
- [MLIR Legacy Path](docs/mlir-legacy.md)
