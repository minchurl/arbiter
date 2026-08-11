# Arbiter Overview

This document is the source of truth for Arbiter's current design.

## Current Direction

Arbiter is a compiler-assisted placement system for coherence-sensitive memory
objects in tiered memory environments.

The current implementation direction is the LLVM-only hot-set experiment. Its
compile-time policy has two deliberately separate stages:

1. HITM-risk selection scores allocation sites and freezes a small set of seed
   roots using only `ARBITER_HITM_*` controls.
2. Hot-set selection follows bounded paths from those roots and adds attached
   allocations whose read/write affinity passes the `ARBITER_HOTSET_*` policy.

Stage 2 never drops, replaces, or reorders the Stage 1 roots. If a hot-set site
or byte cap cannot contain every selected root, the config is invalid rather
than silently changing the seed set.

The current target is allocation-time placement on remote NUMA or CXL-like
memory. Despite the experiment name, Arbiter does not move already-allocated
objects during the measured run.

The detailed policy, config reference, and experiment methodology live in
[Access-Affinity Hot Set Placement](hotset-migration.md).

## Document Map

- [Access-Affinity Hot Set Placement](hotset-migration.md): current heuristic,
  config, and experiment contract.
- [Shared-Mutable Pattern Placement](shared-mutable-pattern-placement.md):
  earlier point-based heuristic retained as an independent baseline.
- [LLVM-Only Design](llvm-only-design.md): generic allocation-site reporting,
  rewriting, and runtime ownership model.
- [Experiment Results](experiments/README.md): durable result ledgers.
- [Lock-Touch Page Migration](lock-touch-page-migration.md): runtime-hook
  comparison path, not the current direction.
- [MLIR Legacy Path](mlir-legacy.md): legacy precision/reference path.

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

## Architecture

```text
C/C++ benchmark + one build-time experiment config
  -> clang/clang++ LLVM IR
  -> Stage 1 HITM-risk seed selection
  -> Stage 2 access-affinity hot-set selection
  -> Arbiter site and hot-set reports
  -> hot-set rewrite pass
  -> LLVM IR with selected arbiter_*_site calls
  -> native binary linked with Arbiter runtime
  -> allocation-time placement from ARBITER_TARGET_NODE
```

All LLVM allocation experiments use the same `ARBITER_TARGET_NODE` runtime
policy. Unset means local allocation; a node ID enables target placement.

## Compiler Passes

Reporting and rewriting are separate so every experiment can inspect its
decision before producing a binary. Both stages import parameters from the same
config and are recorded in one effective-arguments manifest.

```text
arbiter-report-sites
  -> emits allocation and mmap candidates
  -> does not modify IR

arbiter-report-hotset-sites
  -> Stage 1 scores sites and freezes HITM-risk seed roots
  -> Stage 2 discovers and selects hot-set members
  -> reports seed/member/rejected roles
  -> does not modify IR

arbiter-experiment-hotset-rewrite
  -> repeats the deterministic hot-set selection
  -> rewrites the selected hot set
```

`arbiter-experiment-all-rewrite` remains the broad all-site baseline.
`arbiter-report-shared-mutable-sites` and
`arbiter-experiment-shared-mutable-rewrite` remain the earlier point-based
baseline. The hot-set scorer is implemented independently, so changes to its
weights and expansion policy cannot change shared-mutable behavior.

All allocation experiments reuse the existing generic site collector,
`RewritePlan`, and heap/mmap rewriters. The hot-set pass only supplies the
selected IDs.

## Runtime Placement

The LLVM path lowers experiment-selected sites to site-aware runtime calls:

```c
void *arbiter_alloc_site(uint64_t size, uint64_t align,
                         uint32_t site_id, uint32_t reserved);

void *arbiter_calloc_site(uint64_t count, uint64_t elem_size,
                          uint64_t align, uint32_t site_id, uint32_t reserved);

void *arbiter_mmap_site(uint64_t size, int prot, int mmap_flags,
                        uint32_t site_id, uint32_t reserved);

void arbiter_free_maybe(void *ptr);
void arbiter_cxx_delete_maybe(void *ptr);
void arbiter_cxx_delete_array_maybe(void *ptr);
int arbiter_munmap_maybe(void *ptr, uint64_t size);
```

The ABI remains unchanged; its final `uint32_t` slot is reserved and emitted as
zero. The runtime consults `ARBITER_TARGET_NODE` for the single target node.

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
Heap-site alignment is not enforced in the current LLVM path; the `align`
argument is reserved for future aligned allocation support.

## Benchmark Scope

The current benchmarks are GUPS and XIndex/YCSB.

GUPS allocates its primary data region with anonymous `mmap`, so a malloc-only
baseline is insufficient. The generic all-site experiment covers its anonymous
mmap and heap sites.

XIndex allocates important index structures through C++ allocation paths such
as `new`, `new[]`, and `std::malloc`. Arbiter must support C++ allocation and
deallocation ABI forms while avoiding placement-new rewrites. The hot-set
experiment narrows placement to scored seeds and attached read/write-coupled
members, so YCSB trace/input buffers do not move merely because they share a
function, callee, or source file with XIndex structures.

## Measurement Model

The minimum hot-set comparison is:

```text
native
shared-mutable-local
hotset-single
hotset-use-local
hotset-use-target
```

The local runs isolate compiler/runtime overhead from placement. Seed-only and
access-affinity runs isolate the value of placing attached read/write-coupled
allocations. Every result should retain the hot-set CSV and resolved
`hotset-effective.opt-args` manifest. Target comparisons must report
`HITM/op`, total and foreground throughput, and p99 latency together.

## Next Analysis

- optional bounded MemorySSA plus AliasAnalysis as a Stage 2 backend for
  memory-mediated member paths
- profile-derived dynamic allocation-size and live-byte estimates
- profile-guided allocation-site co-access after pointers escape
- loop hotness and write-intensity signals
- indirect-call-aware worker reachability
- automated staged config sweeps tied to throughput, latency, and HITM/C2C data
