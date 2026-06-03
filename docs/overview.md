# Arbiter Overview

This document is the source of truth for Arbiter's current design.

## Overview

Arbiter is a compiler-assisted placement system for coherence-sensitive memory
objects in tiered memory environments.

The current implementation direction is LLVM-only for benchmark execution.
Arbiter compiles C/C++ benchmarks to LLVM IR, reports candidate allocation and
mapping sites, rewrites explicitly selected sites to Arbiter runtime calls, and
places selected objects on a configured target memory node such as remote NUMA
memory or CXL-like memory.

The first target is allocation-time placement. Arbiter does not move objects
after the program starts running.

## Motivation

In cache-coherent multicore systems, shared writable cache lines can become
expensive because of coherence activity. NUMA and tiered-memory systems make
this cost more visible and provide placement targets for Arbiter.

When multiple cores repeatedly access the same cache line and at least one core
writes, ownership can move between cores, other cached copies can be
invalidated, and coherence misses or interconnect traffic can increase.

Arbiter therefore focuses on allocation-backed or mapping-backed memory objects
likely to create significant coherence overhead because they are shared,
written, and accessed in parallel.

The hypothesis is not that CXL or remote NUMA memory eliminates cache
coherence. Cacheable CPU loads and stores still participate in the coherence
protocol regardless of where the backing memory is placed.

Instead, Arbiter tests whether object placement can change where coherence
traffic is handled, how much pressure it creates on shared interconnects and
memory controllers, and how much it interferes with other hot data. The
expected benefit exists only when the reduction in coherence-related pressure
is larger than the added latency penalty of the target memory tier.

## Current Architecture

```text
C/C++ benchmark
  -> clang/clang++ LLVM IR
  -> Arbiter LLVM pass plugin
  -> LLVM IR with selected runtime calls
  -> native binary linked with Arbiter runtime
  -> run with ARBITER_TARGET_NODE
```

The LLVM path is the primary benchmark path because it can cover large C/C++
codebases without requiring a source-to-memref frontend.

The earlier MLIR/memref path is retained as a legacy precision/reference path.
It is documented separately in [MLIR Legacy Path](mlir-legacy.md) and is not
used by the current LLVM-only benchmark workflow.

## Compiler Design

The current LLVM compiler path keeps reporting separate from the benchmark
experiment pass.

```text
arbiter-report-sites
  -> emits allocation and mmap candidates
  -> does not modify IR

arbiter-experiment-all-rewrite
  -> selects every supported heap allocation and anonymous mmap site
  -> rewrites them to site-aware runtime calls
  -> rewrites free/delete/munmap calls to side-table-aware maybe helpers
```

Experiment passes carry selection results in an in-memory `RewritePlan`. They
do not tag IR. The plan records selected allocation/mmap sites separately from
broad deallocation coverage, so Arbiter does not need to solve malloc/free
pairing before rewriting `free`, C++ delete, or `munmap` call sites.

The benchmark pass is intentionally all-select for the first LLVM-only
experiment. More advanced static scoring and narrower experiment passes are
future work.

## Runtime Placement

The LLVM path lowers experiment-selected sites to site-aware runtime calls:

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

The runtime uses an internal sharded side table to track only selected
Arbiter-managed pointers. This lets deallocation call sites be rewritten
conservatively:

```text
arbiter_free_maybe(ptr):
  if ptr is tracked by Arbiter:
    remove side-table entry and release with the matching Arbiter backend
  else:
    fall back to ordinary free
```

The same design is used for C++ delete fallbacks and for `munmap` through
`arbiter_munmap_maybe`. The LLVM site-aware ABI does not call the header-based
MLIR `arbiter_alloc` ABI; the side table is the ownership record for this path.
Heap-site alignment is not enforced in the first LLVM path; the `align`
argument is reserved for future aligned allocation support.

## Benchmark Scope

The first benchmarks are GUPS and XIndex/YCSB.

GUPS allocates its primary data region with anonymous `mmap`, so a malloc-only
LLVM pass is insufficient. The first experiment rewrites all supported
anonymous mmap and heap sites.

XIndex allocates important index structures through C++ allocation paths such
as `new`, `new[]`, and `std::malloc`. Arbiter must support C++ allocation and
deallocation ABI forms while avoiding placement-new rewrites.

Future narrower XIndex experiments should avoid moving YCSB trace/input
buffers when isolating the placement effect of XIndex's own data structures.

## Measurement Model

Every benchmark should be measured in three configurations:

```text
native baseline
instrumented with local fallback
instrumented with ARBITER_TARGET_NODE set
```

The local fallback run isolates compiler/runtime overhead from the placement
effect.

## Future Analysis

After the all-select baseline is stable, Arbiter can add static site scoring
and narrower experiment passes:

- parallel escape analysis
- write-intensity analysis
- loop hotness estimation
- atomic, RMW, fence, and lock-pattern detection
- GEP offset and cache-line bucket analysis
- profile-guided allocation-site ranking
