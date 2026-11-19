# Architecture and code map

Arbiter rewrites selected allocation calls at compile time. Local and CXL runs
use the same rewritten binary; only the selected allocations' NUMA node changes.
Ordinary allocations remain under the process's normal memory policy.

## Code reading order

Paths below are relative to the repository root.

| Order | File or directory | Responsibility |
|---|---|---|
| 1 | `compiler/llvm/lib/AllocationSite.cpp` | Discover supported allocations and assign deterministic site IDs |
| 2 | `compiler/llvm/lib/hitm_seed/HITMRiskScoring.cpp` and `ObjectAccessAnalysis.cpp` | Trace object accesses; score, filter and select sites |
| 3 | `compiler/llvm/lib/hitm_seed/HITMSeedOptions.cpp` and `HITMSeedPasses.cpp` | Policy options, CSV decisions and selected-site rewrite |
| 3a | `compiler/llvm/lib/hitm_seed/CompanionAnalysis.cpp` | Optional common-worker-loop candidates; does not change seed selection |
| 4 | `compiler/llvm/lib/RewriteHeapAllocations.cpp` and `RewriteMMapAllocations.cpp` | Rewrite allocation/deallocation calls to the runtime ABI |
| 5 | `runtime/include/arbiter_runtime_site.h` and `runtime/src/arbiter_runtime_site.cpp` | C/C++ allocation contracts, diagnostics and mmap |
| 6 | `runtime/src/arbiter_jemalloc_arena.cpp` | Per-site jemalloc arenas, NUMA extent hooks and ownership lookup |
| 7 | `scripts/build-xindex-llvm.sh` and `run-protected-hitm-seed-experiment.sh` | Build variants, run protected comparisons and validate reports |

Active LLVM pipelines are `arbiter-report-sites`,
`arbiter-experiment-all-rewrite`, `arbiter-report-hitm-seed-sites` and
`arbiter-experiment-hitm-seed-rewrite`. The opt-in
`arbiter-report-companion-sites` pipeline reports additional candidates only.
Generic all-site rewriting and GUPS
remain infrastructure checks; the active placement policy is seed-only.

## Selection

The score combines pointer escape, synchronization/mutation, worker reachability
and allocation size. Gates, score threshold and top-k select seeds in descending
score order, breaking ties by site ID. The static byte budget rejects an
oversized selection at compile time; it does not bound actual runtime memory.
Report and rewrite repeat the same deterministic decision. Site IDs depend on
source/compiler/optimization settings; automatic policies do not pin them.

The existing published-RMW weight also covers allocation-linked RMW/CAS through
object fields, function arguments/returns and resolved indirect calls. Direct
global matches retain `published-pointee-atomic-rmw`; the extended analysis
reports `object-pointee-atomic-rmw`. The weight is added once even when both
paths match. No new policy options or workload-specific site IDs are introduced.

`ObjectAccessAnalysis.cpp` tracks heap-allocation origins and byte-offset fields,
keeping finite field alternatives separate and widening array induction paths.
Field-load caches are versioned per object; stores invalidate every aliased
destination. Calls use one call-site of context. Pointer-sized scalar copies and
constant-size memcpy/memmove are supported. A modeled RMW address must resolve
to one allocation site before it earns the new signal; multi-origin/unknown-origin
results do not.
This is bounded, flow-insensitive evidence discovery, **not a sound whole-program
alias analysis or proof of sharing**. Arbitrary external side effects, dynamic
memory copies, pointer encoding and other C++ ABIs can hide accesses. Exceeding
128 rounds or 2,048 contexts discards all partial new evidence with a diagnostic.

Worker discovery handles direct `pthread_create` and the tested LLVM 18 /
libstdc++ 11 `std::thread` ABI, following the actual state object's vtable to
`_M_run`, then its callback/lambda. The only out-of-line container summary models
libstdc++'s four `_List_node_base::_M_hook` pointer stores; no libcuckoo type names
are matched. See GCC's [thread state](https://github.com/gcc-mirror/gcc/blob/releases/gcc-11.4.0/libstdc%2B%2B-v3/include/bits/std_thread.h)
and [list insertion](https://github.com/gcc-mirror/gcc/blob/releases/gcc-11.4.0/libstdc%2B%2B-v3/src/c%2B%2B98/list.cc).
Worker reasons are now named `thread-worker-entry` / `thread-worker-reachable`.

This selects the microbenchmark table while excluding read-only ballast, and
finds libcuckoo's separately allocated spinlock vector through its owning list.
It cannot prove runtime frequency, multiple writers, or a CXL speedup. B-tree
uses unsupported `posix_memalign`, so its automatic rewrite still selects nothing.

For the retained XIndex build, raw-046/evidence-balanced/published-RMW select
`68,71,74,90,97,98,99,100`; only `68,71,74` allocate during full YCSB-A.
The [config guide](../configs/hitm-seed/README.md) explains policy choices,
parameters and analysis limits. Hardware measurements are separate from selection.

## Companion candidates

`CompanionAnalysis.cpp` reuses allocation provenance and worker discovery to
report selected seeds and other heap allocations accessed in a common worker
loop. Accesses in nested retry loops also contribute to their enclosing loops;
the report retains the deepest common loop depth for each pair/function,
merging access kinds when several loops have that depth. Loads,
stores and RMW/CAS are classified separately. Ambiguous or unresolved modeled
call contexts do not earn a unique allocation link. Synthetic unconstrained
function roots are excluded from this report when actual call contexts exist.
Ordinary seed scoring does not collect
or consume this optional access map, and its policy/options are unchanged.

This finds the microbenchmark's separately allocated read-only ballast without
matching its name, size or site ID. It is **candidate evidence**, not a frequency
measurement, dependence proof, critical-section classification, or prediction
that moving an object is beneficial. Both accesses must appear in a common
loop in the same analyzed function; call-graph reachability alone does not
summarize callee accesses into a caller's loop. Disjoint paths can still produce
may-co-access candidates.

The earlier `UseBasedHotSet` implementation (PR #10, removed in #11) instead
followed seed-owned pointer members and ranked their accesses. Its isolated
replay is retained with the experiment evidence; it is not restored as an
active compiler policy. These two relations find different candidates. Existing
seed-only rewriting remains the default; experiments generate an explicit-site
override from candidate reports and separately validate a placement plan.

## Adaptive companion experiment

`arbiter-experiment-adaptive-rewrite` is a separate opt-in pipeline. It keeps
the seed policy and expands only one unambiguous common-loop domain. Multiple
domains, missing provenance, and unsuitable loop exits retain the ordinary
seed rewrite. No benchmark names, input arguments, or saved throughput profiles
participate in this decision.

`AdaptiveExperiment.cpp` derives a progress signal from the selected loop.
For a fixed-trip inner loop, progress can be published in batches at its
dedicated exit. When ScalarEvolution proves an existing atomic 64-bit store
has the recurrence `{{1,+,batch}<outer>,+,1}<inner>`, the pass can instead
register its global counter range. Array stride and field offset come from
LLVM types and GEPs; each observed field must be initially zero. Padding may be
undefined because it is never read. This path inserts registration in a module
constructor and leaves the worker body unchanged. Unsupported counter layouts
use separate padded counters, which add instructions to the work path.

These are structural progress proxies, not proof of application-level requests,
tail latency, or fairness. Monotonicity checks reject observed resets; they do
not prove that arbitrary external writers or variable work per iteration are
absent. A positive result on one recognized program is not evidence that every
application supplies a usable progress metric.

The separately linked `arbiter_adaptive_experiment` library starts companions
locally, measures progress, and tries the same 12.5/25/50% ladder on every input.
It accepts a gain above 2%, stops expansion after a loss above 3%, and aborts a
probe early for a loss above 15%. Three consecutive monitoring windows below
85% of the settled rate trigger a fresh local-placement comparison. These are
common experimental controller constants, not new seed-scoring options.
`ARBITER_ADAPTIVE_MODE=observe` runs the same observer without migration;
`adapt` enables the controller and is the default for this experimental binary.

The controller queries resident pages of compiler-registered sites through
`arbiter_visit_site_extents`, migrates only those pages with `move_pages`, and
checks per-page results and a 4 GiB current-resident companion budget. It demotes
before promoting. This budget is distinct from the fixed placement API's
lifetime mapping budget; seed pages are excluded. Mappings are retained, but
freed objects and allocator metadata may share their pages. New allocations
and refaulted pages initially remain local: `move_pages` does not change their
allocation policy. The prototype therefore targets stable, long-lived objects,
not arbitrary allocation churn. Migration can temporarily stall application
accesses and has to be charged to end-to-end performance.

It is a research implementation, not a default runtime feature. It does not
optimize several progress domains, continuously re-explore after settling at
zero, enforce latency SLAs, or guarantee that an unknown input never loses
performance during exploration. The [results report](results.md) separates
same-binary control comparisons, observer overhead, migration costs and scope.

## Why jemalloc still needs NUMA hooks

A separate page per small object wastes memory: an early 357,388-object,
96-byte pilot used 43.63 MiB with packed slabs, versus about 1.36 GiB if each
object occupied a 4 KiB page. The custom slab solved packing; jemalloc now
handles size classes, reuse and statistics without maintaining that machinery.

An ordinary jemalloc allocation does not take a NUMA-node argument. Each active
site therefore gets an explicit arena whose extent hook obtains an aligned
anonymous `mmap` and calls `mbind(MPOL_BIND)` before returning memory to jemalloc.
`mallocx`/`dallocx` bypass the thread cache so objects cannot cross arena policies.
This retains packing and NUMA placement without a pre-reserved pool.
[jemalloc arena and extent API](https://jemalloc.net/jemalloc.3.html)

An extent-range registry distinguishes selected pointers from ordinary pointers
for `*_maybe` deallocation wrappers. Ordinary pointers use their matching
`free`/`delete` ABI. There is no per-object side table, live bitmap, page-owner
table, fixed object shape or pool capacity. Invalid/interior/double frees have
ordinary allocator undefined behavior. Mappings and hooks survive static
teardown; jemalloc can reuse extents and purge their physical pages.

## Placement and failure contract

| Setting | Meaning |
|---|---|
| `ARBITER_TARGET_NODE` | Required target NUMA node, read once per process |
| `ARBITER_ARENA_SLOT_ALIGNMENT` | Minimum heap alignment, default 64 bytes |
| `ARBITER_ARENA_REPORT=1` | Enable exit-time allocation and residency reports; default off |
| `ARBITER_HEAP_BACKEND=arena`, `ARBITER_ARENA_STRICT=1` | Optional compatibility settings; other values fail |
| `ARBITER_ARENA_RESERVE_BYTES`, `ARBITER_ARENA_SLAB_BYTES` | Obsolete; ignored with a warning |

Selected allocations are strict: binding/allocation failure never retries on
ordinary DRAM. Limit memory with a process/cgroup limit. One site may request
mixed sizes/alignments, including objects larger than the former chunk limit.

An opt-in `arbiter_set_site_placement(site, local_node, target_percent,
max_target_bytes)` call configures a heap site before its first allocation.
Supported percentages are 0 (local), 50 (page interleave between local and
target), and 100 (target first). A finite cap limits the lifetime total of
target-backed **mappings**, including jemalloc metadata and unused capacity;
it is not a live-payload/RSS limit. A cap smaller than one page grants no target
pages. `UINT64_MAX` means unlimited. For 50%, an odd interleaved range is charged
conservatively for its extra page. Freed/purged mappings remain charged because
jemalloc can reuse them; budgets are not refunded.

Once a site's budget is consumed, further backing is intentionally local. This
is the configured policy, not recovery from a failed target allocation: mapping
or binding errors still fail strictly. Unconfigured sites retain their original
target-only behavior, and mmap is unchanged. Repeated/late configuration returns
`EBUSY`. Plans do not migrate existing memory, detect slowdown, or adapt online.
Per-site caps are independent; a process-wide companion allowance can be divided
between sites before execution. Seed allocations outside those plans are not
included in that allowance. The exit report's `arbiter-placement-site` lines
record each plan and its cumulative charge.

| API | Failure behavior |
|---|---|
| `malloc`, `calloc` | NULL with errno; calloc overflow is ENOMEM |
| Throwing `new`/`new[]`, including aligned forms | Honor `new_handler`; retry the same arena if it returns; throw `bad_alloc` when no handler remains |
| Nothrow `new`/`new[]` | Catch exceptions from the throwing helper and return NULL |
| Selected `mmap` | MAP_FAILED and errno; failed binding releases the new mapping |

Failures log `arbiter-allocation-failure` with API, site, bytes, alignment,
configured node, stage and errno. Zero-size heap requests return a freeable
allocation; `free` preserves errno. The compiler preserves `invoke` unwind
edges and operand bundles, and leaves unsupported/placement-new signatures alone.
Returned failures can be diagnosed; later page-fault OOM or process termination
cannot be recovered by these wrappers.

Selected mmap supports private anonymous, non-fixed mappings. It preserves
protections and strictly binds/migrates populated pages or fails. Shared,
file-backed and fixed mappings are outside this wrapper's contract; unselected
mappings are unchanged. `munmap` forwards to the kernel, including partial unmaps.
The heap extent report does not include these separate mmap allocations.

## Reading a heap report

Reporting requires stats-enabled jemalloc. `allocated_bytes` is current usable
live allocation size; `assigned_bytes` is mapped backing including retained
capacity and metadata. Neither is RSS. `object_bytes=0` denotes mixed requested
sizes at a site. Removed peak/cumulative/capacity fields stay empty in legacy CSVs.
`fallback_allocations=0` remains for compatibility, not as a failed-request count.

`mincore` and `move_pages` locate private resident pages. Mapped kernel zero
pages returning `-EFAULT` are rechecked and counted separately as `zero_pages`;
other query failures remain errors. Valid comparisons require all located
private pages on the requested node, not merely a majority. Live-object tests
also write and query touched pages independently.

See [benchmark validation](benchmarks.md#validation-and-measurement) and
[design history](results.md#design-history) for the tests and decisions behind
this contract.
