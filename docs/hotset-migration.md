# HITM-Risk Seed Placement

Arbiter's current hot-set experiment selects heap allocation sites that appear
likely to create coherence pressure and rewrites those sites for local or CXL
placement. Selection is entirely compile-time and deterministic:

```text
allocation sites
  -> HITM-risk scoring
  -> automatic top-k or explicit seed selection
  -> selected-byte budget validation
  -> heap allocation rewrite
  -> local or target-node allocation at runtime
```

Despite the historical `hotset-migration` name, the runtime performs
allocation-time placement. It does not migrate already allocated pages.

## Scope Decision

An earlier implementation followed bounded pointer paths from selected seeds
and added related allocation sites using read/write affinity. The completed
XIndex/YCSB-A sweep did not need that expansion for its strongest result:
`raw-046` used seed selection only and averaged 27.886M local versus 56.813M
CXL op/s in the homogeneous 180-second final stage.

Member expansion and its affinity, call-depth, load-depth, mmap, and per-seed
cap controls were removed from the active pipeline to reduce analysis and
configuration complexity. The implementation remains available in git history
and the `experiment/hotset-migration` branch. Historical experiment documents
and artifacts retain their original fields so that past runs remain
reproducible.

This removal is not a claim that related-object placement cannot help another
benchmark. It records that the feature was not required by the validated
XIndex candidate and did not justify its maintenance cost in the main path.

## HITM-Risk Scoring

`compiler/llvm/lib/hotset/HITMRiskScoring.*` implements a static risk proxy.
It does not read hardware HITM counters. Each allocation site can receive one
contribution from each applicable signal:

| Config | Signal | Default |
|---|---|---:|
| `ARBITER_HITM_WEIGHT_ESCAPE_RETURN` | allocation escapes through return | 3 |
| `ARBITER_HITM_WEIGHT_ESCAPE_STORE` | allocation-derived pointer is stored | 3 |
| `ARBITER_HITM_WEIGHT_ESCAPE_CALL` | pointer reaches a non-ignored call | 2 |
| `ARBITER_HITM_WEIGHT_SYNC_ATOMIC` | atomic RMW or cmpxchg in the function | 3 |
| `ARBITER_HITM_WEIGHT_SYNC_STORE` | atomic or volatile store in the function | 2 |
| `ARBITER_HITM_WEIGHT_SYNC_INLINE_ASM` | lock/cmpxchg inline assembly | 2 |
| `ARBITER_HITM_WEIGHT_SYNC_FILE` | synchronization mutation in the debug file | 1 |
| `ARBITER_HITM_WEIGHT_WORKER_ENTRY` | allocation in a pthread worker entry | 3 |
| `ARBITER_HITM_WEIGHT_WORKER_REACHABLE` | allocation reachable from a worker | 2 |
| `ARBITER_HITM_WEIGHT_SIZE` | large or dynamically sized allocation | 1 |

Automatic candidates must satisfy the configured gates and minimum score.
They are ordered by score descending and site ID ascending, then truncated to
the configured seed limit.

| Config | Default | Meaning |
|---|---:|---|
| `ARBITER_HITM_MIN_SCORE` | 6 | minimum automatic-seed score |
| `ARBITER_HITM_SEED_LIMIT` | 3 | maximum automatic seeds |
| `ARBITER_HITM_SEED_SITE_IDS` | empty | explicit comma-separated heap site IDs |
| `ARBITER_HITM_REQUIRE_ESCAPE` | 1 | require an escape signal |
| `ARBITER_HITM_REQUIRE_SYNC` | 1 | require a sync or mutable signal |
| `ARBITER_HITM_LARGE_ALLOCATION_THRESHOLD` | 4096 | size-score threshold; 0 disables it |
| `ARBITER_HITM_INCLUDE_DYNAMIC_SIZE` | 1 | give dynamic allocations the size score |

Explicit site IDs replace automatic selection. They must exist and must be heap
allocations. Explicit seeds bypass the score threshold, gates, and automatic
seed limit, but are still ordered deterministically for reporting.

Weights affect the score but not the underlying gates. For example, setting an
escape weight to zero removes its score contribution while the detected escape
can still satisfy `ARBITER_HITM_REQUIRE_ESCAPE`.

## Placement Budget

Two options constrain the static size estimate of the selected seeds:

| Config | Default | Meaning |
|---|---:|---|
| `ARBITER_HOTSET_DYNAMIC_SIZE_ESTIMATE` | 4096 | bytes charged for a selected dynamic-size seed |
| `ARBITER_HOTSET_MAX_ESTIMATED_BYTES` | 0 | total static seed budget; 0 is unlimited |

The dynamic estimate changes only budget accounting, not the HITM-risk score.
If the selected seeds exceed a nonzero byte budget, compilation fails instead
of silently changing the selected set.

The fixed-slot arena requires one stable allocation size and alignment per
site. Full-trace drivers therefore reject selected nonconstant-size sites even
when the compile-time byte estimate would fit.

## Passes and Report

The active pass pair remains:

```text
arbiter-report-hotset-sites
arbiter-experiment-hotset-rewrite
```

The report pass emits one row per allocation site without modifying IR:

```text
site_id,kind,function,file,line,callee,size_expr,estimated_bytes,score,role,group_id,selected,reasons
```

`role` is either `seed` or `rejected`. `group_id` records deterministic seed
order and is zero for rejected sites. The rewrite pass repeats the same
selection and rewrites only selected heap allocations. It does not select mmap
sites; generic mmap placement remains available through the all-site and other
independent experiments.

## Building XIndex

Build a checked-in policy:

```sh
ARBITER_XINDEX_EXPERIMENT=hotset \
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-cxl-arena.config \
./scripts/build-xindex-llvm.sh
```

The build retains:

```text
ycsb_bench.hotset-sites.csv
ycsb_bench.hotset-effective.opt-args
```

Keep both files with every result. Site IDs are deterministic for one LLVM
module but can change with source, compiler, or optimization changes.

Useful checked-in policies include:

- `xindex-cxl-arena.config`: small automatic seed reference;
- `xindex-cxl-arena-auto-k{1,2,3,4,6}-*.config`: bounded automatic top-k
  policies;
- `xindex-cxl-arena-seed-size-heavy.config`: seed-only reconstruction of the
  full-trace `raw-046` finalist;
- `xindex-cxl-arena-site99-baseline.config`: build-specific reproduction-only
  explicit seed.

## Runtime Placement

Selected allocations lower to the existing site-aware runtime ABI. Both local
and CXL rows use the same rewritten binary. Only the target node changes:

```text
local:  ARBITER_HEAP_BACKEND=arena ARBITER_TARGET_NODE=0
CXL:    ARBITER_HEAP_BACKEND=arena ARBITER_TARGET_NODE=<cxl-node>
```

The arena backend reserves one virtual range, binds it with `mbind`, and
assigns fixed-size slabs to `(site ID, object size, requested alignment)`
arenas. Allocation normally uses an atomic bump; locks are limited to slow
paths such as installing a slab or recycling freed slots. Arena pointers are
recognized by their address range, so they do not require per-object side-table
entries.

| Environment | Typical value | Meaning |
|---|---:|---|
| `ARBITER_ARENA_SLAB_BYTES` | 2097152 | bytes per slab |
| `ARBITER_ARENA_RESERVE_BYTES` | 4294967296 or larger | virtual reservation and hard arena capacity |
| `ARBITER_ARENA_SLOT_ALIGNMENT` | 64 | minimum slot alignment |
| `ARBITER_ARENA_STRICT` | 1 | fail instead of falling back to direct allocation |
| `ARBITER_ARENA_REPORT` | 1 | report per-site counters and physical residency |

The reservation uses `MAP_NORESERVE`; untouched pages do not contribute to
RSS. At exit, the runtime reports allocations, fallbacks, assigned slabs, and
resident pages by NUMA node.

## Protected Comparison

Run the same rewritten binary with local and CXL arenas:

```sh
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-cxl-arena-seed-size-heavy.config \
ARBITER_TARGET_NODE=<cxl-node> \
./scripts/run-protected-hotset-experiment.sh
```

The result labels are:

```text
native
hotset-seed-local
hotset-seed-target
```

Interpret them separately:

```text
compiler/runtime overhead = hotset-seed-local / native
CXL placement effect      = hotset-seed-target / hotset-seed-local
end-to-end effect         = hotset-seed-target / native
```

The local/CXL comparison is primary because it holds the binary, selected
sites, allocator, workload, and worker counts constant.

## Claim Boundary

The 2026-10-06 full-trace sweep found a large and repeatable throughput signal
for seed-only policies, including about +104% for `raw-046` in four paired
180-second final-stage runs. That experiment did not collect HITM/C2C or p99
latency and did not validate operation return values with a final checksum.

Accordingly, a placement result should retain:

- native, seed-local, and seed-target throughput;
- selected static and runtime-active site fingerprints;
- RSS, arena residency, fallback, swap, and OOM counters;
- the input config, effective LLVM arguments, and binary hashes.

Before attributing the gain to reduced coherence, add correctness checks,
HITM/C2C counters, memory-bandwidth counters, and tail latency.

## Implementation Boundaries

Seed placement code lives under `compiler/llvm/lib/hotset/`:

- `HITMRiskScoring`: scoring, gates, ordering, selection, and byte-budget
  validation;
- `HotSetPasses`: report and heap-rewrite plumbing;
- `HotSetOptions`: compile-time policy options.

The generic allocation-site collector, `RewritePlan`, heap rewriter, runtime
ABI, and arena backend remain shared with other experiments. Removing member
expansion does not change the runtime ABI or allocator implementation.
