# Arbiter

Arbiter is a compiler-assisted placement system for coherence-sensitive
memory objects in tiered memory environments.

The current benchmark workflow is LLVM-only: C/C++ benchmarks are lowered to
LLVM IR, an Arbiter LLVM pass plugin reports and rewrites selected allocation
sites, and the runtime places selected objects on a configured target memory
node such as remote NUMA memory or CXL-like memory.

The earlier MLIR/memref path is retained as a precision/reference path, but it
is not used by the current LLVM-only benchmark workflow. See
[MLIR MemRef Path](docs/mlir-memref-path.md).

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

Arbiter builds against LLVM/MLIR 18.

Required:

- CMake 3.20 or newer
- Ninja
- C++17 compiler, such as `clang++`
- LLVM/MLIR 18 development packages
- `opt`, `llvm-link`, and `FileCheck` for LLVM pass checks
- `libnuma-dev` on Linux for target-node placement

On Ubuntu 24.04:

```sh
sudo apt install cmake ninja-build clang-18 llvm-18-dev mlir-18-tools libnuma-dev
```

Configure and build:

```sh
cmake -S . -B build-llvm18 -G Ninja \
  -DCMAKE_C_COMPILER=/usr/lib/llvm-18/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/lib/llvm-18/bin/clang++ \
  -DMLIR_DIR=/usr/lib/llvm-18/lib/cmake/mlir

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
./scripts/run-gups-arbiter.sh
./scripts/run-xindex-arbiter.sh
```

The first supported benchmarks are:

- GUPS: primary data region is anonymous `mmap`, so mmap rewriting is required.
- XIndex/YCSB: primary index structures are C++ heap objects, so C++ allocation
  ABI rewriting is required.

## MLIR Reference Path

The MLIR tool remains available for memref-level experiments:

```sh
ARBITER_BUILD_DIR=build-llvm18 ./scripts/smoke.sh
```

This path is useful for precise object-boundary analysis, but it is not the
main benchmark path.

## Docs

- [Overview](docs/overview.md)
- [LLVM-Only Design](docs/llvm-only-design.md)
- [Benchmark Plan](docs/benchmark-plan.md)
- [MLIR MemRef Path](docs/mlir-memref-path.md)
