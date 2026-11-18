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
| 4 | `compiler/llvm/lib/RewriteHeapAllocations.cpp` and `RewriteMMapAllocations.cpp` | Rewrite allocation/deallocation calls to the runtime ABI |
| 5 | `runtime/include/arbiter_runtime_site.h` and `runtime/src/arbiter_runtime_site.cpp` | C/C++ allocation contracts, diagnostics and mmap |
| 6 | `runtime/src/arbiter_jemalloc_arena.cpp` | Per-site jemalloc arenas, NUMA extent hooks and ownership lookup |
| 7 | `scripts/build-xindex-llvm.sh` and `run-protected-hitm-seed-experiment.sh` | Build variants, run protected comparisons and validate reports |

Active LLVM pipelines are `arbiter-report-sites`,
`arbiter-experiment-all-rewrite`, `arbiter-report-hitm-seed-sites` and
`arbiter-experiment-hitm-seed-rewrite`. Generic all-site rewriting and GUPS
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
