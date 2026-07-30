# Read/Write-Coupled Access-Affinity Hot Set Placement

The hot-set experiment makes two independent compile-time decisions:

1. `HITMRiskScoring` ranks heap allocation sites and chooses a small set of
   coherence-sensitive seeds.
2. `UseBasedHotSet` follows bounded seed-relative access paths and selects only
   attached allocations with sufficient read/write affinity.

The selected sites keep the existing Arbiter runtime ABI. Target placement is
baked into the existing `flags` operand, while `flags=0` preserves the earlier
runtime-configured behavior.

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
sweep requires rebuilding but adds no policy lookup to the measured hot path.

## Independent Seed Scoring

Seed selection is unchanged. The hot-set implementation has an independent
copy of the shared-mutable-style point heuristic under
`compiler/llvm/lib/hotset/HITMRiskScoring.*`; changing it cannot change the
existing shared-mutable pass.

The score is a static HITM-risk proxy, not proof that a site generated HITM.
It favors allocations that escape, are near synchronization or mutable
operations, occur in pthread worker code, or are large/dynamically sized.
Actual HITM/C2C data is an experiment result.

Automatic seeds must pass the configured escape/sync gates and
`ARBITER_HOTSET_MIN_SCORE`. They are ordered by score descending and site ID
ascending, then limited by `ARBITER_HOTSET_SEED_LIMIT`.

`ARBITER_HOTSET_SEED_SITE_IDS` replaces automatic selection with explicit
sites. Explicit seeds must exist, must be heap allocations, and must fit the
global site and estimated-byte budgets.

Seed score controls:

| Config | Signal | Default |
| --- | --- | ---: |
| `ARBITER_HOTSET_WEIGHT_ESCAPE_RETURN` | allocation escapes through return | 3 |
| `ARBITER_HOTSET_WEIGHT_ESCAPE_STORE` | allocation-derived pointer is stored | 3 |
| `ARBITER_HOTSET_WEIGHT_ESCAPE_CALL` | pointer is passed to a non-ignored call | 2 |
| `ARBITER_HOTSET_WEIGHT_SYNC_ATOMIC` | atomic RMW or cmpxchg in the same function | 3 |
| `ARBITER_HOTSET_WEIGHT_SYNC_STORE` | atomic or volatile store in the same function | 2 |
| `ARBITER_HOTSET_WEIGHT_SYNC_INLINE_ASM` | lock/cmpxchg inline assembly in the same function | 2 |
| `ARBITER_HOTSET_WEIGHT_SYNC_FILE` | sync mutation in the same debug file | 1 |
| `ARBITER_HOTSET_WEIGHT_WORKER_ENTRY` | allocation in a pthread worker entry | 3 |
| `ARBITER_HOTSET_WEIGHT_WORKER_REACHABLE` | allocation reachable from a pthread worker | 2 |
| `ARBITER_HOTSET_WEIGHT_SIZE` | configured large or dynamic allocation | 1 |

Seed gates and size controls:

| Config | Default | Effect |
| --- | ---: | --- |
| `ARBITER_HOTSET_MIN_SCORE` | 6 | minimum automatic-seed score |
| `ARBITER_HOTSET_SEED_LIMIT` | 3 | maximum automatic seeds after score ordering |
| `ARBITER_HOTSET_SEED_SITE_IDS` | empty | comma-separated explicit heap seed IDs |
| `ARBITER_HOTSET_REQUIRE_ESCAPE` | 1 | require an escape signal |
| `ARBITER_HOTSET_REQUIRE_SYNC` | 1 | require a sync or mutable signal |
| `ARBITER_HOTSET_LARGE_ALLOCATION_THRESHOLD` | 4096 | bytes required for the size score; 0 disables it |
| `ARBITER_HOTSET_INCLUDE_DYNAMIC_SIZE` | 1 | award the size score to dynamic allocations |
| `ARBITER_HOTSET_DYNAMIC_SIZE_ESTIMATE` | 4096 | bytes charged to a dynamic site for static budgeting |

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

With `MIN_SCORE=6`, `REQUIRE_ESCAPE=1`, and `REQUIRE_SYNC=1`, that site is an
automatic-seed candidate. Repeating ten stores or atomics does not multiply
the corresponding signal.

The three same-function synchronization signals can contribute independently.
The file-level sync weight is a fallback used only when the allocation's own
function has none of them. Likewise, a pthread worker entry receives the entry
weight instead of also receiving the worker-reachable weight.

The gates and weights are independent. Setting a weight to zero removes its
score contribution, but the underlying signal can still satisfy
`REQUIRE_ESCAPE` or `REQUIRE_SYNC`. Explicit seed IDs bypass the score,
minimum, gates, and `SEED_LIMIT`; they still must be heap sites and fit
`MAX_SITES` and `MAX_ESTIMATED_BYTES`. Explicit IDs are reordered
deterministically by score descending and site ID ascending, not by the order
written in the config.

`INCLUDE_DYNAMIC_SIZE` controls only whether a dynamic allocation receives the
size point. `DYNAMIC_SIZE_ESTIMATE` is still the number of bytes charged to a
selected dynamic site by the static byte budget.

## Access-Affinity Expansion

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
evidence. Within each seed group, members are ordered by affinity descending,
access depth ascending, and site ID ascending. Selection then applies:

1. `ARBITER_HOTSET_MEMBER_MIN_AFFINITY`,
2. `ARBITER_HOTSET_MAX_MEMBERS_PER_SEED`,
3. `ARBITER_HOTSET_MAX_SITES`, and
4. `ARBITER_HOTSET_MAX_ESTIMATED_BYTES`.

A member that exceeds the byte budget is skipped so a later, smaller member
can still fit. Anonymous mmap can be a member only with
`ARBITER_HOTSET_INCLUDE_MMAP=1`; mmap is never a seed.

Member boundary controls:

| Config | Default | Effect |
| --- | ---: | --- |
| `ARBITER_HOTSET_EXPANSION` | `use` | `none` selects seeds only; `use` discovers members |
| `ARBITER_HOTSET_MEMBER_MIN_AFFINITY` | 3 | valid values are 1, 3, and 5 |
| `ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH` | 1 | direct-call traversal depth, 0-4 |
| `ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH` | 2 | pointer-load traversal depth, 0-4 |
| `ARBITER_HOTSET_MAX_MEMBERS_PER_SEED` | 4 | member cap per seed; 0 is unlimited |
| `ARBITER_HOTSET_MAX_SITES` | 16 | total seed and member cap |
| `ARBITER_HOTSET_MAX_ESTIMATED_BYTES` | 0 | static byte budget; 0 is unlimited |
| `ARBITER_HOTSET_INCLUDE_MMAP` | 0 | allow anonymous mmap members |

The threshold values intentionally skip 2:

- `MIN_AFFINITY=5` selects only write-coupled candidates.
- `MIN_AFFINITY=3` selects read- and write-coupled candidates.
- `MIN_AFFINITY=1` selects attach, pointer-only, read, and write candidates.

Thus affinity-2 pointer evidence is visible in the CSV but is selected only by
the broad affinity-1 experiment.

Depth zero has a concrete meaning. `MAX_LOAD_DEPTH=0` does not follow a pointer
load from an attachment slot, so a directly attached candidate remains
affinity 1. `MAX_CALL_DEPTH=0` does not enter a direct callee body; the call
boundary is classified from argument/function memory attributes, or as
pointer-only when no useful attribute exists. Increasing a depth can discover
new candidates or strengthen existing evidence, and can therefore also change
cross-seed assignment and cap outcomes.

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

In this example:

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

## Build-Time Config

Build XIndex with a checked-in or generated config:

```sh
ARBITER_XINDEX_EXPERIMENT=hotset \
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-sweep-base.config \
./scripts/build-xindex-llvm.sh
```

The script sources the config, validates removed keys, and translates every
resolved value into an explicit `opt` argument. It writes:

```text
ycsb_bench.hotset-sites.csv
ycsb_bench.hotset-effective.opt-args
```

Keep both files with each benchmark result. The manifest records the complete
effective policy, including defaults, so a run does not depend on ambient
shell state. Removed `ARBITER_HOTSET_EXPAND_SCOPE` and
`ARBITER_HOTSET_MEMBER_MIN_SCORE` keys fail with a migration error instead of
being ignored.

Placement controls:

| Config | Default | Effect |
| --- | ---: | --- |
| `ARBITER_HOTSET_PLACEMENT` | `local` | emit zero flags or encode a target node |
| `ARBITER_HOTSET_TARGET_NODE` | 0 | target node 0-255 |
| `ARBITER_HOTSET_REPORT_PATH` | build directory | CSV output path |

The runtime ABI and generic rewriters are unchanged. Existing hot-set flags
encode:

- bit 0: compile-time target placement enabled,
- bits 8-15: target node ID.

Target node 1 therefore produces `257`; target node 3 produces `769`.
`ARBITER_HOTSET_PLACEMENT=local` emits `flags=0`, so local baselines must run
with `ARBITER_TARGET_NODE` unset.

## How Parameters Compose

The pass applies parameter groups in this order:

1. score every supported allocation site,
2. choose automatic or explicit heap seeds,
3. discover seed-relative attachments and their strongest affinity,
4. assign shared candidates to one seed group,
5. apply affinity, member, site, and byte limits, and
6. encode the selected placement in rewritten calls.

This ordering is important:

- score weights and seed gates never rank members,
- member affinity never changes seed selection,
- `MAX_MEMBERS_PER_SEED` is applied after affinity/depth ordering,
- `MAX_SITES` includes both seeds and members,
- selected seeds consume the byte budget before members, and
- a member that does not fit the byte budget is skipped rather than ending the
  scan.

Common tuning goals map to parameters as follows:

| Goal | Parameter change |
| --- | --- |
| select fewer, stronger seeds | raise `MIN_SCORE` or lower `SEED_LIMIT` |
| reproduce one known seed set | set `SEED_SITE_IDS` |
| isolate write-coupled members | set `MEMBER_MIN_AFFINITY=5` |
| add active read members | set `MEMBER_MIN_AFFINITY=3` |
| audit every statically attached member | set `MEMBER_MIN_AFFINITY=1` |
| follow deeper helper calls | raise `MEMBER_MAX_CALL_DEPTH` |
| follow nested pointer containers | raise `MEMBER_MAX_LOAD_DEPTH` |
| reduce analysis breadth/false positives | lower call/load depth |
| bound static hot-set cardinality | lower member and total site caps |
| bound estimated placement volume | set `MAX_ESTIMATED_BYTES` |
| compare seed-only placement | set `EXPANSION=none` |

Depth increases are not guaranteed to produce a strict superset because
stronger evidence can reassign a candidate to another seed group before caps
are applied. In contrast, with the same seeds and other limits, the affinity
ordering keeps every site in `set(5)` in `set(3)`, and every site in `set(3)`
in `set(1)`.

## Config Recipes

Config files are sourced by the build script. Omitted variables use the
defaults recorded in the effective opt-args manifest, so a recipe may contain
only the values it intends to vary.

### Read-Coupled Target Baseline

This is the default experiment shape: up to three seeds, read and write
members, bounded one direct call and two pointer loads, placed on node 1.

```sh
ARBITER_HOTSET_MIN_SCORE=6
ARBITER_HOTSET_SEED_LIMIT=3
ARBITER_HOTSET_EXPANSION=use

ARBITER_HOTSET_MEMBER_MIN_AFFINITY=3
ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH=1
ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH=2
ARBITER_HOTSET_MAX_MEMBERS_PER_SEED=4
ARBITER_HOTSET_MAX_SITES=16

ARBITER_HOTSET_PLACEMENT=target
ARBITER_HOTSET_TARGET_NODE=1
```

### Tight Write-Only Target

Use this to test whether write-coupled members alone provide the effect while
keeping the hot set small. The example permits at most three seeds and two
members per seed, subject to a nine-site and 64 MiB static budget.

```sh
ARBITER_HOTSET_SEED_LIMIT=3
ARBITER_HOTSET_EXPANSION=use
ARBITER_HOTSET_MEMBER_MIN_AFFINITY=5
ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH=1
ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH=2
ARBITER_HOTSET_MAX_MEMBERS_PER_SEED=2
ARBITER_HOTSET_MAX_SITES=9
ARBITER_HOTSET_MAX_ESTIMATED_BYTES=67108864
ARBITER_HOTSET_INCLUDE_MMAP=0
ARBITER_HOTSET_PLACEMENT=target
ARBITER_HOTSET_TARGET_NODE=1
```

### Broad Ownership Audit

Use affinity 1 to inspect what the static closure can reach before deciding
which members should be remote. The explicit IDs make the seed boundary stable
for one exact build. Unlimited member and byte values are written as zero.

```sh
ARBITER_HOTSET_SEED_SITE_IDS=69,97,99
ARBITER_HOTSET_EXPANSION=use
ARBITER_HOTSET_MEMBER_MIN_AFFINITY=1
ARBITER_HOTSET_MEMBER_MAX_CALL_DEPTH=3
ARBITER_HOTSET_MEMBER_MAX_LOAD_DEPTH=3
ARBITER_HOTSET_MAX_MEMBERS_PER_SEED=0
ARBITER_HOTSET_MAX_SITES=64
ARBITER_HOTSET_MAX_ESTIMATED_BYTES=0
ARBITER_HOTSET_INCLUDE_MMAP=1
ARBITER_HOTSET_PLACEMENT=local
```

This recipe is intentionally broad and is best used to inspect the CSV before
running a target experiment. Site IDs are valid only for the matching source,
compiler, optimization pipeline, and allocation-site report.

### Seed-Scoring Sweep Point

This example favors atomic-adjacent sites, removes the size contribution, and
keeps only the highest-scoring automatic seed:

```sh
ARBITER_HOTSET_MIN_SCORE=9
ARBITER_HOTSET_SEED_LIMIT=1
ARBITER_HOTSET_REQUIRE_ESCAPE=1
ARBITER_HOTSET_REQUIRE_SYNC=1
ARBITER_HOTSET_WEIGHT_SYNC_ATOMIC=5
ARBITER_HOTSET_WEIGHT_SIZE=0
ARBITER_HOTSET_EXPANSION=none
ARBITER_HOTSET_PLACEMENT=local
```

Always compare the generated CSV before and after changing score weights.
Changing a weight can alter both which seeds pass `MIN_SCORE` and their top-k
order.

## Report

The `arbiter-report-hotset-sites` pass emits:

```text
site_id,kind,function,file,line,callee,size_expr,estimated_bytes,score,role,group_id,selected,flags,target_node,reasons,member_affinity,member_access_kind,member_access_depth
```

Roles are `seed`, `member`, or `rejected`. Selected member reasons include the
strongest evidence and seed group:

```text
hotset-member:access-affinity:kind=read:score=3:seed-group=N
hotset-member:access-affinity:kind=write:score=5:seed-group=N
```

Common rejection reasons include:

```text
hotset-rejected:below-member-affinity:score=N
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

Compare `MEMBER_MIN_AFFINITY=5`, `3`, and `1` under the same workload. Affinity
5 isolates write-coupled placement, affinity 3 adds read-coupled members, and
affinity 1 adds ownership-only members.

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

`hotset-single` uses `ARBITER_HOTSET_EXPANSION=none`. Local runs isolate
compiler/runtime overhead and must unset `ARBITER_TARGET_NODE`.

The useful search space includes seed weights and gates, explicit or top-k
seeds, affinity threshold, call/load depths, member/site/byte caps, dynamic
size assumptions, mmap inclusion, placement node, workload, thread counts,
foreground thread counts, and repeats. Sweep one family at a time and retain
the config, CSV, effective argument manifest, binary identity, and metrics.

## Limits and Next Direction

This is a static, bounded, control-flow-insensitive heuristic. A normalized
path can connect equivalent static accesses, but it cannot prove temporal
co-access. Dynamic indices with equal strides may alias in the model even when
runtime indices differ.

The analysis intentionally excludes indirect calls, callee return
propagation, pointer/integer round trips, and general points-to analysis. Once
a pointer escapes outside the bounded seed-relative path, later runtime access
cannot be recovered reliably.

### Future MemorySSA-Backed Analysis

The next static-analysis step should use LLVM
[`MemorySSA`](https://llvm.org/docs/MemorySSA.html) together with
`AliasAnalysis`. The current tracer follows SSA values directly, but it stops
when a seed-relative address is stored into memory and recovered later.

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

A bounded MemorySSA extension could recover the relation:

1. Treat the store to `%slot.box` as a `MemoryDef`.
2. Ask the MemorySSA walker for the clobbering definition of the load from
   `%slot.box`.
3. Use alias analysis and value propagation to recover that
   `%recovered.slot` represents the original seed-relative `%slot`.
4. Relate the load from `%recovered.slot` to the member attachment store.
5. Reuse the existing downstream classifier, raising the member to affinity 5
   because `%recovered.member` is written.

`MemoryPhi` nodes can similarly expose branch-merged memory definitions. If
two possible attachment stores reach one member load, the analysis must either
retain both as conservative candidates or reject the ambiguous relation. That
choice should be explicit in the report rather than hidden in a score.

The KISS implementation path is:

1. keep `HITMRiskScoring`, seed selection, affinity levels, and caps unchanged,
2. run the current direct SSA analysis first,
3. invoke MemorySSA only for unresolved memory-mediated paths,
4. start with same-function `MustAlias` relations,
5. reuse the existing `pointer/read/write` evidence classifier, and
6. bound every MemorySSA walk and report its provenance.

Possible future config keys, not implemented today, are:

| Future config | Purpose |
| --- | --- |
| `ARBITER_HOTSET_MEMBER_ANALYSIS=ssa|memoryssa` | compare the current boundary with MemorySSA expansion |
| `ARBITER_HOTSET_MEMORYSSA_ALIAS=must|may` | choose strict or conservative alias acceptance |
| `ARBITER_HOTSET_MEMORYSSA_MAX_WALK` | bound clobber-chain traversal |
| `ARBITER_HOTSET_MEMORYSSA_MAX_DEFS_PER_LOAD` | cap ambiguous reaching definitions |

MemorySSA does not replace alias analysis: it versions memory operations, while
AA decides which locations may refer to the same memory. It is also a
per-function analysis, so indirect calls, uninlined cross-function pointer
flows, and callee return propagation still require summaries or a separate
interprocedural layer. Finally, MemorySSA describes static reaching
definitions, not runtime temporal co-access or access frequency.

Profile-guided allocation-site co-access is the next precision step if the
static boundary is insufficient. Runtime profiling can rank co-access, while
the final experiment still bakes the selected set into IR.

Site IDs are deterministic for one LLVM module but can change with source,
compiler, or optimization changes. Explicit-site configs must stay with the
CSV, effective argument manifest, and exact build input.

## Implementation Isolation

Hot-set code lives under `compiler/llvm/lib/hotset/`:

- `HITMRiskScoring`: seed score and automatic-seed gate,
- `UseBasedHotSet`: seed selection and bounded access-affinity discovery,
- `HotSetPasses`: report/rewrite plumbing and placement-flag baking,
- `HotSetOptions`: compile-time policy options.

The generic `RewritePlan`, heap/mmap rewriters, shared-mutable pass, runtime
ABI, and placement-flag layout are not changed by the access-affinity
revision.
