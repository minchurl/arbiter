# Read/Write-Coupled Access-Affinity Hot Set Placement

The hot-set experiment has two deliberately separate compile-time stages:

1. **HITM-risk seed selection:** `HITMRiskScoring` ranks heap allocation sites
   and freezes a small set of coherence-sensitive seed roots. Only
   `ARBITER_HITM_*` parameters affect this stage.
2. **Hot-set member selection:** `UseBasedHotSet` starts from those fixed roots,
   follows bounded seed-relative access paths, and adds attached allocations
   according to `ARBITER_HOTSET_*` parameters.

Stage 2 never drops, replaces, or reorders Stage 1 roots. Total hot-set caps
include the roots; a cap that cannot contain all of them is a config error. One
config file supplies both parameter groups, and one effective-arguments
manifest records the complete resolved policy.

The selected sites keep the existing Arbiter runtime ABI. The direct backend
uses the single runtime `ARBITER_TARGET_NODE` setting; unset means host
allocation. The slab/arena backend requires an explicit node for both local
and target runs.

Despite the historical "migration" name, this is allocation-time placement.
It does not move pages after allocation.

## Why Compile-Time Hot Sets

The earlier `function`, `file`, and `worker` expansion scopes used allocation
definition location as a proxy for related data. Those scopes can include
unrelated allocations and miss objects accessed through loaded pointers.

The first use-based revision was also too permissive:

- storing `new ColdData()` under a seed proved ownership, not co-access,
- a direct callee could contain unrelated temporary allocations, and
- site-ID order, rather than access relevance, decided which members survived
  a cap.

The current boundary requires both an attachment to a seed-relative path and
static evidence about how that path is used. It stays deliberately bounded and
deterministic rather than becoming a general alias analysis.

The lock-touch page-migration experiment remains a historical comparison. It
adds synchronization-address hooks to runtime hot paths. Hot-set placement
instead makes allocation-object decisions during compilation, so a config
sweep requires rebuilding but adds no per-allocation hot-set membership lookup
to the measured hot path.

## Stage 1: HITM-Risk Seed Selection

The hot-set implementation has an independent copy of the
shared-mutable-style point heuristic under
`compiler/llvm/lib/hotset/HITMRiskScoring.*`; changing it cannot change the
existing shared-mutable pass.

The score is a static HITM-risk proxy, not proof that a site generated HITM.
It favors allocations that escape, are near synchronization or mutable
operations, occur in pthread worker code, or are large/dynamically sized.
Actual HITM/C2C data is an experiment result.

Automatic seeds must pass the configured escape/sync gates and
`ARBITER_HITM_MIN_SCORE`. They are ordered by score descending and site ID
ascending, then limited by `ARBITER_HITM_SEED_LIMIT`.

`ARBITER_HITM_SEED_SITE_IDS` replaces automatic selection with explicit sites.
Explicit seeds must exist and must be heap allocations. Stage 1 freezes the
result without consulting hot-set affinity, traversal, or budget parameters.

Seed score controls:

| Config | Signal | Default |
| --- | --- | ---: |
| `ARBITER_HITM_WEIGHT_ESCAPE_RETURN` | allocation escapes through return | 3 |
| `ARBITER_HITM_WEIGHT_ESCAPE_STORE` | allocation-derived pointer is stored | 3 |
| `ARBITER_HITM_WEIGHT_ESCAPE_CALL` | pointer is passed to a non-ignored call | 2 |
| `ARBITER_HITM_WEIGHT_SYNC_ATOMIC` | atomic RMW or cmpxchg in the same function | 3 |
| `ARBITER_HITM_WEIGHT_SYNC_STORE` | atomic or volatile store in the same function | 2 |
| `ARBITER_HITM_WEIGHT_SYNC_INLINE_ASM` | lock/cmpxchg inline assembly in the same function | 2 |
| `ARBITER_HITM_WEIGHT_SYNC_FILE` | sync mutation in the same debug file | 1 |
| `ARBITER_HITM_WEIGHT_WORKER_ENTRY` | allocation in a pthread worker entry | 3 |
| `ARBITER_HITM_WEIGHT_WORKER_REACHABLE` | allocation reachable from a pthread worker | 2 |
| `ARBITER_HITM_WEIGHT_SIZE` | configured large or dynamic allocation | 1 |

Seed gates and size controls:

| Config | Default | Effect |
| --- | ---: | --- |
| `ARBITER_HITM_MIN_SCORE` | 6 | minimum automatic-seed score |
| `ARBITER_HITM_SEED_LIMIT` | 3 | maximum automatic seeds after score ordering |
| `ARBITER_HITM_SEED_SITE_IDS` | empty | comma-separated explicit heap seed IDs |
| `ARBITER_HITM_REQUIRE_ESCAPE` | 1 | require an escape signal |
| `ARBITER_HITM_REQUIRE_SYNC` | 1 | require a sync or mutable signal |
| `ARBITER_HITM_LARGE_ALLOCATION_THRESHOLD` | 4096 | bytes required for the size score; 0 disables it |
| `ARBITER_HITM_INCLUDE_DYNAMIC_SIZE` | 1 | award the size score to dynamic allocations |

Each signal contributes its configured weight at most once per static site.
For example, a 4096-byte allocation that escapes through both a store and a
call, and whose function contains an atomic RMW, receives:

```text
escape-store  3
escape-call   2
sync-atomic   3
size          1
----------------
total         9
```

With `ARBITER_HITM_MIN_SCORE=6`, `ARBITER_HITM_REQUIRE_ESCAPE=1`, and
`ARBITER_HITM_REQUIRE_SYNC=1`, that site is an automatic-seed candidate.
Repeating ten stores or atomics does not multiply the corresponding signal.

The three same-function synchronization signals can contribute independently.
The file-level sync weight is a fallback used only when the allocation's own
function has none of them. Likewise, a pthread worker entry receives the entry
weight instead of also receiving the worker-reachable weight.

The gates and weights are independent. Setting a weight to zero removes its
score contribution, but the underlying signal can still satisfy
`ARBITER_HITM_REQUIRE_ESCAPE` or `ARBITER_HITM_REQUIRE_SYNC`. Explicit seed IDs
bypass the score, minimum, gates, and `ARBITER_HITM_SEED_LIMIT`. They are
reordered deterministically by score descending and site ID ascending, not by
the order written in the config.

`ARBITER_HITM_INCLUDE_DYNAMIC_SIZE` controls only whether a dynamic allocation
receives the size point. `ARBITER_HOTSET_DYNAMIC_SIZE_ESTIMATE` belongs to
Stage 2 and controls only how many bytes a selected dynamic site is charged by
the static hot-set budget. It cannot affect which roots Stage 1 selects.

## Stage 2: Hot-Set Member Selection

`ARBITER_HOTSET_EXPANSION` has two values:

- `none`: select only seeds.
- `use`: discover attached members and apply the affinity threshold.

An allocation becomes a member candidate only when its allocation-derived
pointer is stored into a seed-relative path. Merely allocating inside a
function that receives the seed is not enough.

The analysis follows:

- `getelementptr`, `bitcast`, `addrspacecast`, `phi`, `select`, and `freeze`,
- direct defined callees through the corresponding formal argument, up to
  `ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH`, and
- pointer loads, up to `ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH`.

GEP paths are normalized with the module `DataLayout`: constant byte offsets
and dynamic-index strides form the path key. Each pointer load adds one path
level. The analysis does not follow indirect calls, pointer/integer round
trips, callee returns, or general points-to relationships.

Each seed trace is capped at 4096 unique `(value, path, call-depth)` states to
bound loop-carried path walks.

For each attached candidate, only its strongest observed evidence is retained:

| Affinity | Access kind | Evidence |
| ---: | --- | --- |
| 1 | `attach` | allocation-derived pointer is attached to a seed-relative path |
| 2 | `pointer` | attachment slot is loaded, null-checked, or used by a pointer-only/unknown call |
| 3 | `read` | member pointee is loaded or passed to a readonly call |
| 5 | `write` | member pointee is stored/atomically updated or passed to a mutating call |

Evidence is not added by frequency. Ten reads still produce affinity 3, and
one or more writes produce affinity 5.

`memcpy` source is read affinity, `memcpy` destination and `memset`
destination are write affinity. `readnone`, `readonly`, and `writeonly`
attributes map to pointer, read, and write affinity respectively. An external
call without useful body or memory attributes stays at pointer affinity.
Free, delete, and munmap do not count as member access evidence.

When one static candidate is reachable from multiple seeds, ownership is
resolved by:

1. affinity descending,
2. access depth ascending, and
3. seed group ascending.

Access depth is the call depth plus pointer-load depth of the strongest
evidence. After ownership is resolved, all members are ordered globally by
affinity descending, access depth ascending, seed group ascending, and site ID
ascending. The global affinity-first order keeps lower affinity thresholds
from displacing members already selected by a higher threshold. Selection then
applies:

1. `ARBITER_HOTSET_MEMBER_MIN_AFFINITY`,
2. `ARBITER_HOTSET_MAX_MEMBERS_PER_SEED`,
3. `ARBITER_HOTSET_MAX_SITES`, and
4. `ARBITER_HOTSET_MAX_ESTIMATED_BYTES`.

Before member selection, Stage 2 verifies that the site cap and any nonzero byte
cap can contain all frozen roots. An insufficient cap is a config error; roots
are never truncated to make the config fit. Roots consume the budgets first,
then members use the remaining capacity. A member that exceeds the byte budget
is skipped so a later, smaller member can still fit. Anonymous mmap can be a
member only with `ARBITER_HOTSET_INCLUDE_MMAP=1`; mmap is never a seed.

Member boundary controls:

| Config | Default | Effect |
| --- | ---: | --- |
| `ARBITER_HOTSET_EXPANSION` | `use` | `none` selects seeds only; `use` discovers members |
| `ARBITER_HOTSET_MEMBER_MIN_AFFINITY` | 3 | valid values are 1, 3, and 5 |
| `ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH` | 1 | direct-call traversal depth, 0-4 |
| `ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH` | 2 | pointer-load traversal depth, 0-4 |
| `ARBITER_HOTSET_MAX_MEMBERS_PER_SEED` | 4 | member cap per seed; 0 is unlimited |
| `ARBITER_HOTSET_MAX_SITES` | 16 | total root and member cap; too small for roots is an error |
| `ARBITER_HOTSET_MAX_ESTIMATED_BYTES` | 0 | total static byte budget; 0 is unlimited; too small for roots is an error |
| `ARBITER_HOTSET_DYNAMIC_SIZE_ESTIMATE` | 4096 | bytes charged to each dynamic selected site |
| `ARBITER_HOTSET_INCLUDE_MMAP` | 0 | allow anonymous mmap members |

The threshold values intentionally skip 2:

- `ARBITER_HOTSET_MEMBER_MIN_AFFINITY=5` selects only write-coupled candidates.
- `ARBITER_HOTSET_MEMBER_MIN_AFFINITY=3` selects read- and write-coupled candidates.
- `ARBITER_HOTSET_MEMBER_MIN_AFFINITY=1` selects attach, pointer-only, read, and write candidates.

Thus affinity-2 pointer evidence is visible in the CSV but is selected only by
the broad affinity-1 experiment.

Depth zero has a concrete meaning.
`ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH=0` does not follow a pointer load from an
attachment slot, so a directly attached candidate remains affinity 1.
`ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH=0` does not enter a direct callee body;
the call boundary is classified from argument/function memory attributes, or
as pointer-only when no useful attribute exists. Increasing a depth can
discover new candidates or strengthen existing evidence, and can therefore
also change cross-seed assignment and cap outcomes.

## Why Read-Coupled Members

A hot-set member does not need to generate HITM itself. A remote access on the
same operation path can increase the interval between successive writes or lock
hand-offs on the seed, reducing the rate of ownership transfers.

```cpp
lock(meta->lock);

read(meta->name);
read(meta->schema);

entry = meta->entries[i];
entry->update();

unlock(meta->lock);
```

- `meta->lock` is the contention anchor.
- `name` and `schema` are read-coupled members.
- `entry` is a write-coupled member.

The experiment separates these strengths:

| Minimum affinity | Included members |
| ---: | --- |
| 5 | write, atomic, and mutating-call members |
| 3 | active read members plus affinity-5 members |
| 1 | ownership-attached members plus all stronger members |

Read-coupled placement is useful only when it adds latency on the relevant
operation path. If the data remains cache-resident, remote backing-memory
latency may have little effect.

## One Build-Time Config

Build XIndex with a checked-in or generated config:

```sh
ARBITER_XINDEX_EXPERIMENT=hotset \
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-sweep-base.config \
./scripts/build-xindex-llvm.sh
```

The same sourced config contains `ARBITER_HITM_*` Stage 1 controls and
`ARBITER_HOTSET_*` Stage 2 controls. The script translates every resolved value
into an explicit `opt` argument and writes:

```text
ycsb_bench.hotset-sites.csv
ycsb_bench.hotset-effective.opt-args
```

Keep both files with each benchmark result. The manifest records the complete
effective policy for both stages, including defaults.

The same rewritten binary can be used for both placement modes:

```sh
./scripts/run-xindex-arbiter.sh local
ARBITER_TARGET_NODE=1 ./scripts/run-xindex-arbiter.sh remote
```

For a protected, reproducible native/local/target comparison, use the dedicated
driver and explicitly name the machine's CXL NUMA node:

```sh
ARBITER_TARGET_NODE=<cxl-node> \
./scripts/run-protected-hotset-experiment.sh
```

The driver defaults to `configs/hotset/xindex-cxl-arena.config`, a small scaled
workload, and a 60-second time-based measured interval. It records the sourced
config and its SHA-256, the unified decision CSV, resolved `opt` arguments,
binary hashes, per-run maximum RSS, arena counters, and local/target summaries.
The local and target rows use the same rewritten binary and slab allocator;
the arena is bound to `ARBITER_MEM_NODE` for local and `ARBITER_TARGET_NODE`
for target.

The arena config pins the score-14 XIndex `put` root (site 99 in the matching
build) and disables member expansion. The excluded 8-byte member is the first
`std::vector` backing allocation created by `reserve(1)`, not the B-tree node
payload. The explicit ID is valid only for the matching build, which is why the
driver retains the decision CSV and binary hash. The config declares the
expected seed function and selected counts; the driver stops before execution
if those checks drift.

### NUMA Slab/Arena Heap Backend

The legacy direct backend calls `numa_alloc_onnode` and records a side-table
entry for every selected heap object. A 96-byte allocation can therefore
consume one 4KiB page and one locked hash-table insertion. Page-aligned NUMA
pointers also exposed a shard-hash defect: the old low-bit hash sent them all
to shard zero. The direct backend now mixes high address bits, but it remains a
compatibility/reference path rather than the recommended hot-set allocator.

Set `ARBITER_HEAP_BACKEND=arena` to use the pooled path. The runtime reserves
one virtual range, binds it to the requested NUMA node with `mbind`, and assigns
2MiB slabs to `(site ID, object size, requested alignment)` arenas. With the
default 64-byte slot alignment, site 99's 96-byte object uses a 128-byte slot:

```text
2MiB slab on node 0 or node 2
  -> 16,384 fixed 128-byte slots
  -> each slot holds one 96-byte site-99 object
```

Allocation normally needs an atomic bump only; a lock is used when installing
a new slab or recycling freed slots. Deallocation first checks whether the
pointer falls inside the reserved arena range, computes its slab index, checks
the local allocation bitmap, and returns the slot to that arena. Ordinary
heap pointers fall through to their original `free`/`delete`. In strict mode,
ordinary heap deallocations do not probe the heap side table.

Relevant runtime controls are:

| Environment | Driver default | Meaning |
|---|---:|---|
| `ARBITER_HEAP_BACKEND` | `arena` | `direct` or `arena` |
| `ARBITER_ARENA_SLAB_BYTES` | 2097152 | bytes assigned per slab |
| `ARBITER_ARENA_RESERVE_BYTES` | 4294967296 | virtual reservation and hard arena capacity |
| `ARBITER_ARENA_SLOT_ALIGNMENT` | 64 | minimum object alignment and slot rounding |
| `ARBITER_ARENA_STRICT` | 1 | fail instead of using per-object direct fallback |
| `ARBITER_ARENA_REPORT` | 1 | emit per-site and summary allocation counters |

The reservation uses `MAP_NORESERVE`; untouched pages do not count toward RSS.
Assigned slab bytes are capacity, not exact physical residency. At exit,
`mincore` identifies resident pages and `move_pages` reports their actual NUMA
nodes in `arbiter-arena-residency`. The protected driver rejects missing
reports, placement-query errors, node-majority mismatches, and nonzero fallback
counts. Currently each selected site must retain one allocation size and
requested alignment during a process. Dynamic-size sites should remain on the
direct backend until size-class support is added.

`--duration N` makes each foreground worker cycle its assigned trace until N
seconds elapse. The stop flag is checked every 256 operations. The protected
driver exposes this as `XINDEX_DURATION_SECONDS`, defaults it to 60, and uses
`XINDEX_ITERATION` only when the duration is set to zero.

The runtime ABI's final `uint32_t` slot remains reserved and is emitted as
zero.

## Config Recipes

Config files are sourced by the build script. Omitted variables use the
defaults recorded in the effective opt-args manifest, so a recipe may contain
only the values it intends to vary.

### Read-Coupled Baseline

This is the default experiment shape: up to three seeds, read and write
members, bounded one direct call and two pointer loads.

```sh
ARBITER_HITM_MIN_SCORE=6
ARBITER_HITM_SEED_LIMIT=3
ARBITER_HOTSET_EXPANSION=use

ARBITER_HOTSET_MEMBER_MIN_AFFINITY=3
ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH=1
ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH=2
ARBITER_HOTSET_MAX_MEMBERS_PER_SEED=4
ARBITER_HOTSET_MAX_SITES=16
```

### Tight Write-Only Hot Set

Use this to test whether write-coupled members alone provide the effect while
keeping the hot set small. The example permits at most three seeds and two
members per seed, subject to a nine-site and 64 MiB static budget.

```sh
ARBITER_HITM_SEED_LIMIT=3
ARBITER_HOTSET_EXPANSION=use
ARBITER_HOTSET_MEMBER_MIN_AFFINITY=5
ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH=1
ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH=2
ARBITER_HOTSET_MAX_MEMBERS_PER_SEED=2
ARBITER_HOTSET_MAX_SITES=9
ARBITER_HOTSET_MAX_ESTIMATED_BYTES=67108864
ARBITER_HOTSET_INCLUDE_MMAP=0
```

### Broad Ownership Audit

Use affinity 1 to inspect what the static closure can reach before deciding
which members should be remote. The explicit IDs make the seed boundary stable
for one exact build. Unlimited member and byte values are written as zero.

```sh
ARBITER_HITM_SEED_SITE_IDS=69,97,99
ARBITER_HOTSET_EXPANSION=use
ARBITER_HOTSET_MEMBER_MIN_AFFINITY=1
ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH=3
ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH=3
ARBITER_HOTSET_MAX_MEMBERS_PER_SEED=0
ARBITER_HOTSET_MAX_SITES=64
ARBITER_HOTSET_MAX_ESTIMATED_BYTES=0
ARBITER_HOTSET_INCLUDE_MMAP=1
```

This recipe is intentionally broad and is best used to inspect the CSV before
running a target experiment. Site IDs are valid only for the matching source,
compiler, optimization pipeline, and allocation-site report.

### Seed-Scoring Sweep Point

This example favors atomic-adjacent sites, removes the size contribution, and
keeps only the highest-scoring automatic seed:

```sh
ARBITER_HITM_MIN_SCORE=9
ARBITER_HITM_SEED_LIMIT=1
ARBITER_HITM_REQUIRE_ESCAPE=1
ARBITER_HITM_REQUIRE_SYNC=1
ARBITER_HITM_WEIGHT_SYNC_ATOMIC=5
ARBITER_HITM_WEIGHT_SIZE=0
ARBITER_HOTSET_EXPANSION=none
```

Always compare the generated CSV before and after changing score weights.
Changing a weight can alter both which roots pass `ARBITER_HITM_MIN_SCORE` and
their top-k order.

## Unified Decision Report

The `arbiter-report-hotset-sites` pass emits:

```text
site_id,kind,function,file,line,callee,size_expr,estimated_bytes,score,role,group_id,selected,reasons,member_affinity,member_access_kind,member_access_depth
```

Roles are `seed`, `member`, or `rejected`. Member evidence is reported directly
through `group_id`, `member_affinity`, `member_access_kind`, and
`member_access_depth`. Common rejection reasons include:

```text
hotset-rejected:below-member-affinity
hotset-rejected:outside-access-closure
hotset-rejected:per-seed-member-limit
hotset-rejected:max-sites
hotset-rejected:byte-budget
hotset-rejected:mmap-disabled
```

Member `score` remains the independent HITM-risk diagnostic. Selection uses
`member_affinity`, not that score. `estimated_bytes` charges one static
estimate per site; it does not model invocation count, object lifetime, or
live remote bytes.

For example, before caps and byte limits:

| Site | HITM score | Member affinity | Kind | Selected at 5 | Selected at 3 | Selected at 1 |
| --- | ---: | ---: | --- | --- | --- | --- |
| A | 4 | 5 | `write` | yes | yes | yes |
| B | 12 | 3 | `read` | no | yes | yes |
| C | 12 | 1 | `attach` | no | no | yes |

Site A demonstrates that a member can have a low independent HITM score but
still be strongly coupled to its seed. Sites B and C demonstrate that a high
HITM score does not override the configured member-affinity boundary.

## Experiment Interpretation

Arbiter's pacing hypothesis is that remote cache-miss latency can increase the
interval until the seed's next write or lock handoff. That may reduce
ownership transfers and HITM events per unit time. Remote memory does not
remove cache coherence, and a lower `HITM/s` alone is not success.

Every comparison should record:

- `HITM/op`,
- total throughput,
- foreground throughput, and
- p99 tail latency.

Compare `ARBITER_HOTSET_MEMBER_MIN_AFFINITY=5`, `3`, and `1` under the same
workload. Affinity 5 isolates write-coupled placement, affinity 3 adds
read-coupled members, and affinity 1 adds ownership-only members.

If `HITM/op` is unchanged while throughput and `HITM/s` fall together, treat
the result as slowdown, not optimization. Cache-resident readonly members may
rarely pay backing-memory latency and therefore may provide little pacing
effect.

Minimum structural baselines are:

```text
native
shared-mutable-local
hotset-single
hotset-use-local
hotset-use-target
```

`hotset-single` uses `ARBITER_HOTSET_EXPANSION=none`. Direct-backend local runs
unset `ARBITER_TARGET_NODE`; arena-backend local runs bind the arena explicitly
to the baseline memory node. Target runs bind it to the machine's CXL NUMA
node.

The useful search space includes HITM-risk weights and gates, explicit or top-k
roots, affinity threshold, call/load depths, member/site/byte caps, dynamic
size assumptions, mmap inclusion, runtime target node, workload, thread counts,
foreground thread counts, and repeats. Sweep one stage's parameter family at a
time and retain the config, CSV, effective argument manifest, binary identity,
and metrics.

## Limits and Next Direction

This is a static, bounded, control-flow-insensitive heuristic. A normalized
path can connect equivalent static accesses, but it cannot prove temporal
co-access. Dynamic indices with equal strides may alias in the model even when
runtime indices differ.

The analysis intentionally excludes indirect calls, callee return
propagation, pointer/integer round trips, and general points-to analysis. Once
a pointer escapes outside the bounded seed-relative path, later runtime access
cannot be recovered reliably.

### Future MemorySSA Hot-Set Backend

MemorySSA is a possible Stage 2 backend, not part of HITM-risk seed selection.
LLVM [`MemorySSA`](https://llvm.org/docs/MemorySSA.html) together with
`AliasAnalysis` can extend member discovery when a seed-relative address is
stored into memory and recovered later. The frozen Stage 1 roots remain the
same whichever Stage 2 backend is used.

For example, consider this simplified LLVM IR:

```llvm
%slot.box = alloca ptr
%slot = getelementptr %Meta, ptr %seed, i32 0, i32 3

; The member is attached to seed->entry.
store ptr %member, ptr %slot

; The seed-relative slot pointer is spilled and later recovered.
store ptr %slot, ptr %slot.box
%recovered.slot = load ptr, ptr %slot.box
%recovered.member = load ptr, ptr %recovered.slot

; The recovered member is actively written.
store i64 1, ptr %recovered.member
```

The current bounded SSA tracer sees the first attachment, but it does not
follow `%slot` through the store to `%slot.box`. The member therefore remains
affinity 1 even though the later operation is write-coupled.

A bounded extension could ask MemorySSA which store reaches the load from
`%slot.box`, use AliasAnalysis to require a same-function `MustAlias`, recover
the stored `%slot` value, and then resume the existing affinity classifier.
The direct SSA tracer should remain the default path; MemorySSA is only a
bounded fallback for such unresolved spill/reload cases.

MemorySSA versions memory operations but does not replace AliasAnalysis, prove
runtime co-access, or provide access frequency. Indirect calls and
interprocedural pointer flows still need separate handling.

Profile-guided allocation-site co-access is the next precision step if the
static boundary is insufficient. Runtime profiling can rank co-access, while
the final experiment still bakes the selected set into IR.

Site IDs are deterministic for one LLVM module but can change with source,
compiler, or optimization changes. Explicit-site configs must stay with the
CSV, effective argument manifest, and exact build input.

## Implementation Isolation

Hot-set code lives under `compiler/llvm/lib/hotset/`:

- `HITMRiskScoring`: Stage 1 seed scoring, gates, ordering, and root selection,
- `UseBasedHotSet`: Stage 2 bounded access-affinity member discovery,
- `HotSetPasses`: report and rewrite plumbing,
- `HotSetOptions`: compile-time policy options.

The generic `RewritePlan`, heap/mmap rewriters, shared-mutable pass, runtime
ABI, and `ARBITER_TARGET_NODE` policy are shared with other LLVM experiments.
