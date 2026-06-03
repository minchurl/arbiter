# LLVM-Only Design

This document describes Arbiter's current LLVM-only benchmark path.

## Goals

The LLVM path exists to run real C/C++ benchmarks without relying on a
source-to-memref frontend. The first goal is benchmark coverage and controlled
placement experiments, not perfect static identification of coherence-heavy
objects.

## Plugin-Based Pipeline

Arbiter uses an LLVM pass plugin instead of a standalone driver for the first
implementation.

```text
opt -load-pass-plugin ArbiterLLVMPlugin.so \
  -passes="arbiter-report-sites,arbiter-experiment-all-rewrite"
```

Scripts wrap this command for benchmark use. A standalone `arbiter-llvm-opt`
driver can be added later as a thin wrapper if the workflow needs a dedicated
CLI.

## Passes

### arbiter-report-sites

Reports supported allocation and mapping sites. It does not modify IR.

### arbiter-experiment-all-rewrite

Current benchmark experiment. It selects every supported heap allocation and
anonymous mmap site, rewrites them to site-aware runtime calls, and rewrites the
matching free/delete and munmap sites to family-preserving `*_maybe` calls.

Internally, experiment passes build an in-memory `RewritePlan` instead of
tagging IR. The plan separates selected allocation sites from broad
deallocation coverage:

```text
collect allocation/mmap/free/delete/munmap sites once
build RewritePlan from the full module context
apply mmap rewrites from the plan
apply heap rewrites from the plan
```

This keeps future selection logic in experiment passes while keeping rewriters
mechanical.

## Report Format

Reports use CSV:

```text
site_id,kind,function,file,line,callee,size_expr
```

Site IDs are deterministic within a given LLVM module traversal. Source
locations require debug info such as `-gline-tables-only`.

## Supported Calls

Heap calls:

- `malloc`
- `calloc`
- `free`
- C++ `operator new`
- C++ `operator new[]`
- C++ `operator delete`
- C++ `operator delete[]`

Mmap calls:

- anonymous `mmap`
- `munmap`

Not supported in the first implementation:

- `realloc`
- `posix_memalign`
- `aligned_alloc`
- exact heap alignment preservation
- exact sized/aligned C++ delete fallback ABI preservation
- non-anonymous `mmap`
- placement new

## Runtime ABI

```c
void *arbiter_alloc_site(uint64_t size, uint64_t align,
                         uint32_t site_id, uint32_t flags);

void *arbiter_calloc_site(uint64_t count, uint64_t elem_size,
                          uint64_t align, uint32_t site_id, uint32_t flags);

void *arbiter_mmap_site(uint64_t size, int prot, int mmap_flags,
                        uint32_t site_id, uint32_t flags);

void arbiter_free_maybe(void *ptr);
void arbiter_cxx_delete_maybe(void *ptr);
void arbiter_cxx_delete_array_maybe(void *ptr);
int arbiter_munmap_maybe(void *ptr, uint64_t size);
```

The legacy MLIR runtime ABI remains available only when
`ARBITER_ENABLE_MLIR_LEGACY=ON` builds `arbiter_runtime_mlir_legacy`:

```c
void *arbiter_alloc(uint64_t size, uint64_t align);
void arbiter_dealloc(void *ptr);
```

The LLVM site-aware ABI does not call this header-based MLIR ABI. It allocates
from the selected backend directly and treats the side table as the ownership
record for `*_maybe` deallocation.

For the first LLVM implementation, heap-site allocation uses the simplest
backend call available: `malloc` for local fallback or `numa_alloc_onnode` when
`ARBITER_TARGET_NODE` is set. The `align` ABI argument is currently reserved
and is not enforced.

## Side Table

The site-aware runtime records only Arbiter-managed pointers in an internal
side table:

```text
256 shards
hash(pointer) -> shard
std::mutex per shard
std::unordered_map<void *, Entry>
```

This keeps the implementation simple and makes conservative deallocation
rewrites safe. The side table is not intended to be on the load/store hot path.

## Measurement

Benchmarks must be compared in three configurations:

```text
native baseline
instrumented local fallback
instrumented remote target node
```

The local fallback run measures instrumentation and runtime overhead without
remote placement.
