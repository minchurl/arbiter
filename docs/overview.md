# Arbiter Overview

This is the code-reading map for Arbiter's heuristic-guided HITM-risk seed
placement implementation.

## System Flow

```text
XIndex source
  -> clang++ emits LLVM bitcode
  -> AllocationSite assigns deterministic site IDs
  -> HITMRiskScoring scores and selects heap seeds
  -> HITMSeedPasses reports decisions and rewrites selected calls
  -> arbiter_runtime_site dispatches selected allocations
  -> arbiter_jemalloc_arena supplies NUMA-bound extents to jemalloc
  -> the same binary runs with its arena on local node 0 or CXL node 2
```

Only the arena node changes between `hitm-seed-local` and
`hitm-seed-target`. The binary, selected sites, allocator implementation,
workload, and worker count remain fixed.

## Compiler Code

`compiler/llvm/lib/AllocationSite.cpp` discovers supported heap and anonymous
mapping calls and assigns site IDs. `RewriteHeapAllocations.cpp` and
`RewriteMMapAllocations.cpp` implement the common rewrite ABI. The generic
all-site rewrite is retained for infrastructure checks and GUPS.

The XIndex policy is isolated under `compiler/llvm/lib/hitm_seed/`:

- `HITMRiskScoring`: escape/synchronization/worker/size signals, gates,
  deterministic ordering, top-k selection, and byte-budget validation;
- `HITMSeedOptions`: command-line policy parameters;
- `HITMSeedPasses`: CSV reporting and selected heap-site rewriting.

The plugin exposes four active pipelines:

```text
arbiter-report-sites
arbiter-experiment-all-rewrite
arbiter-report-hitm-seed-sites
arbiter-experiment-hitm-seed-rewrite
```

The HITM-risk seed decision report schema is:

```text
site_id,kind,function,file,line,callee,size_expr,estimated_bytes,
score,role,group_id,selected,reasons
```

`role` is `seed` or `rejected`. Report and rewrite independently repeat the
same deterministic selection.

## Runtime Code

Selected heap calls lower to the site-aware ABI declared in
`runtime/include/arbiter_runtime_site.h`. Deallocation sites use `*_maybe`
functions, so ordinary pointers still fall back to normal `free`/`delete`.

The only heap backend is a strict, NUMA-bound jemalloc arena for each active
site. Extent hooks obtain aligned anonymous mappings on demand and bind each
to the requested NUMA node before returning it to jemalloc. Selected allocation
requires `ARBITER_TARGET_NODE`; there is no direct backend or retry on a different backend.
Legacy `ARBITER_HEAP_BACKEND=arena` and `ARBITER_ARENA_STRICT=1` are accepted,
but other values reject allocation with a diagnostic.

Rewritten allocations call `mallocx` with the site's arena, alignment and
thread-cache bypass flags. jemalloc owns size classes, free lists and reuse.
An extent-range registry distinguishes arena pointers from ordinary pointers
before calling `dallocx`. jemalloc supplies allocation/free statistics; there
is no object bitmap, page-owner table, fixed-size-per-site rule or pre-reserved
pool. As with ordinary `free`, invalid/interior/double frees are undefined;
the runtime no longer diagnoses them itself. The runtime returns allocation
failure if mapping, NUMA binding or allocation fails. Process memory limits
replace the old pool capacity. Freed space remains available for jemalloc
reuse; retained mappings and hooks live until process exit.

Selected private anonymous `mmap` calls use real `mmap` followed by strict
`mbind`. Protections are preserved; populated pages must migrate to the target
node or the mapping is released and fails. `munmap` forwards to the kernel,
including partial unmaps. No per-pointer side table remains. Shared, file-backed
and fixed-address mappings are outside this selected-mapping contract and fail;
ordinary unselected mappings are unchanged. Arena reports cover heap extents.

Allocation failures emit `arbiter-allocation-failure` with API family, site,
requested bytes/alignment, configured node, failure stage and errno. `malloc`
and `calloc` return NULL with errno; ordinary `new`/`new[]` honor `new_handler`
and throw `bad_alloc` when no handler remains. Nothrow new catches exceptions
and returns NULL. A handler may retry only the same NUMA arena, never another
backend. Zero-size heap requests receive a freeable allocation. `mmap` returns
MAP_FAILED and preserves the syscall error. `free` preserves errno.

The heap rewriter chooses the C, throwing-new or nothrow-new helper and retains
`invoke` unwind destinations, so a caller's catch block still receives failures.
Placement and unsupported new overload signatures are left unchanged.

## Benchmark Code

- `scripts/build-xindex-llvm.sh` builds native and seed-rewritten XIndex;
- `scripts/run-xindex-arbiter.sh` executes one native/local/remote process;
- `scripts/run-protected-hitm-seed-experiment.sh` builds, launches fresh
  processes, enforces memory limits, validates arena placement, and writes CSVs;
- `scripts/run-xindex-hitm-seed-replay.sh` fixes the current `raw-046` full-scale
  one-pass conditions and records a machine manifest;
- `scripts/run-xindex-ycsb-f.sh` runs the automatic evidence-balanced policy
  on read/read-modify-write F, with native/Local/CXL correctness checks;
- `scripts/validate-xindex-runtime-correctness.sh` runs ABI, arena-boundary,
  and short native/Local/CXL semantic gates;
- `scripts/validate-xindex-runtime-correctness-full.sh` runs a fail-closed
  one-pair or four-pair 100M/400M correctness confirmation;
- `scripts/summarize-xindex-hitm-seed-result.sh` turns one result directory into
  a readable policy, throughput, active-site, placement, and safety report.

The canonical config is `configs/hitm-seed/candidates/raw-046.config`. Eleven
other safe measured policies remain for sensitivity studies.

Active workloads are A and F. F maps each UPDATE in A's trace to a sequential
get and put by the same worker and counts that pair as one logical transaction.
It uses the same allocation runtime and policy as A. B's negative results and
compressed input are archived; its active sweep launchers were removed.

## Measurement Contract

`native` measures the unmodified binary. `hitm-seed-local` and
`hitm-seed-target` use the same rewritten binary and strict arena, bound to
the local and CXL nodes respectively. Therefore:

```text
rewrite/allocator overhead = seed-local / native
CXL placement effect       = seed-target / seed-local
end-to-end effect           = seed-target / native
```

Every row is a fresh process, which resets the index, heap, arena, and runtime
counters. The validated experiment intentionally keeps filesystem page cache
warm and does not flush CPU caches. System-wide `drop_caches` is not invoked
automatically because it requires privilege, affects unrelated jobs, and does
not clear anonymous memory or CPU caches.

The current canonical runner uses fixed-operation iteration mode: each row
consumes the complete 400M-operation transaction trace exactly once and exits.
It does not set a measured-duration cutoff or loop over the trace. Retained
YCSB-A results from the earlier parameter sweep used 15-, 60-, and 180-second
cyclic replay and are labeled as historical protocol results. Retained YCSB-B
screening already used the current one-pass contract.

## Scope

The active repository no longer builds the unused MLIR prototype,
shared-mutable heuristic, lock-touch migration, or broad search controllers.
Historical methods are separated under `docs/history/`. Reusable search inputs
and reportable measurements remain checked in under `configs/` and `results/`;
failed raw runs and removed implementation code remain recoverable from Git
history. This keeps the executable path focused on the seed-only result without
discarding the evidence behind the current claim.

The runtime ABI and XIndex logical result now have explicit correctness checks.
The measured loop retains only the original throughput counter; operation
completion and the optional sampled-state digest are checked after timing.
Per-operation attempted/successful validation counters are not present.
The measured throughput gain does not by itself prove reduced HITM. A causal
claim still requires HITM/C2C, memory-bandwidth, and latency counters.
