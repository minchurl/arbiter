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
  -> arbiter_slab_arena packs fixed-size objects into NUMA-bound slabs
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

Two allocation backends remain:

- `direct`: per-object NUMA allocation plus a sharded ownership side table;
- `arena`: one reserved virtual range divided into site/size/alignment slabs.

The XIndex experiment uses strict arena mode. Each allocation normally takes
an atomic bump slot; locking is limited to slab installation and free-list slow
paths. Arena ownership is recognized by address range, so there is no
per-object side-table lookup. Strict mode fails instead of silently using the
direct backend when a site's shape changes or capacity is exhausted.

## Benchmark Code

- `scripts/build-xindex-llvm.sh` builds native and seed-rewritten XIndex;
- `scripts/run-xindex-arbiter.sh` executes one native/local/remote process;
- `scripts/run-protected-hitm-seed-experiment.sh` builds, launches fresh
  processes, enforces memory limits, validates arena placement, and writes CSVs;
- `scripts/run-xindex-hitm-seed-replay.sh` fixes the current `raw-046` full-scale
  one-pass conditions and records a machine manifest;
- `scripts/summarize-xindex-hitm-seed-result.sh` turns one result directory into
  a readable policy, throughput, active-site, placement, and safety report.

The canonical config is `configs/hitm-seed/candidates/raw-046.config`. Eleven
other safe measured policies remain for sensitivity studies.

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

The measured throughput gain does not by itself prove reduced HITM. A causal
claim still requires correctness checks, HITM/C2C counters, memory-bandwidth
counters, and latency measurements.
