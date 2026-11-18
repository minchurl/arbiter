# HITM-Risk Seed Placement

Arbiter selects allocation sites at compile time and places allocations from
those sites into a NUMA-bound runtime arena. The current runtime places new
objects and never migrates an already allocated object.

## Seed Selection

Each heap allocation receives at most one score contribution from each static
signal:

| Config suffix | Signal |
|---|---|
| `WEIGHT_ESCAPE_RETURN` | allocation-derived pointer is returned |
| `WEIGHT_ESCAPE_STORE` | pointer is stored |
| `WEIGHT_ESCAPE_CALL` | pointer reaches a non-ignored call |
| `WEIGHT_SYNC_ATOMIC` | atomic RMW or cmpxchg in the function |
| `WEIGHT_SYNC_STORE` | atomic or volatile store in the function |
| `WEIGHT_SYNC_INLINE_ASM` | lock/cmpxchg inline assembly |
| `WEIGHT_SYNC_FILE` | synchronization mutation in the source file |
| `WEIGHT_PUBLISHED_RMW` | a global pointer publishes the allocation and its loaded pointee feeds atomic RMW/cmpxchg, default 0 |
| `WEIGHT_WORKER_ENTRY` | allocation is in a pthread entry function |
| `WEIGHT_WORKER_REACHABLE` | allocation is reachable from a worker |
| `WEIGHT_SIZE` | allocation crosses the configured size threshold |

Automatic candidates must pass `ARBITER_HITM_REQUIRE_ESCAPE`,
`ARBITER_HITM_REQUIRE_SYNC`, and `ARBITER_HITM_MIN_SCORE`. They are ordered by
score descending and site ID ascending, then limited by
`ARBITER_HITM_SEED_LIMIT`. `ARBITER_HITM_SEED_SITE_IDS` can replace automatic
selection for debugging, but all retained performance configs leave it empty.

Dynamic-size selection is controlled by `ARBITER_HITM_INCLUDE_DYNAMIC_SIZE`.
The runtime enforces a stable size/alignment per site, so every retained
XIndex policy sets it to zero.

## Static Byte Budget

`ARBITER_HITM_SEED_DYNAMIC_SIZE_ESTIMATE` is the accounting size for a selected
dynamic allocation. `ARBITER_HITM_SEED_MAX_ESTIMATED_BYTES` caps the sum of
selected estimates; zero means unlimited. Exceeding a nonzero budget aborts
compilation rather than silently changing the selected set.

This is only a static guard. Runtime allocation count and live bytes determine
the actual arena footprint and must be read from the arena report.

## Arena Placement

The original slab packed many small allocations on each NUMA-bound page. For
357,388 live 96-byte objects, it used 43.63 MiB of resident memory. Individually
binding one 4 KiB page per object would require 1.36 GiB. The former direct backend
also recorded each pointer in an ownership hash table; both are now removed.
[Site-99 measurements](history/hotset-results.md)

The jemalloc backend keeps that packing and placement contract. Each active
site gets an explicit jemalloc arena. Its extent hook obtains an aligned
anonymous mapping with `mmap` and applies `mbind(MPOL_BIND)` before returning
it to jemalloc. There is no up-front reservation. jemalloc splits, merges and
reuses extents, growing its backing mappings on demand. Both
allocation and deallocation bypass the thread cache to preserve placement
across sites and ordinary heap traffic. [jemalloc arena API](https://jemalloc.net/jemalloc.3.html)

| Runtime variable | Replay value | Meaning |
|---|---:|---|
| `ARBITER_TARGET_NODE` | 0 or 2 | required NUMA node |
| `ARBITER_HEAP_BACKEND` | `arena` | optional compatibility setting; only arena is accepted |
| `ARBITER_ARENA_SLOT_ALIGNMENT` | 64 | minimum slot alignment |
| `ARBITER_ARENA_STRICT` | 1 | optional compatibility setting; only 1 is accepted |
| `ARBITER_ARENA_REPORT` | 1 | emit allocation and residency counters |

Selected heap allocation always uses jemalloc and returns failure without
retrying another backend. Ordinary pointers still use their original
`free`/`delete` ABI. Legacy `direct` or `strict=0` settings reject selected
allocation with a diagnostic. Configuration is read once per process.

Failure diagnostics identify API family, site, request size/alignment, configured
node, stage and errno (for example `stage=mbind errno=1`). C allocations return
NULL with errno; throwing C++ new honors `new_handler` and ultimately throws
`bad_alloc`; nothrow new returns NULL if the throwing path fails. Handler retries
stay on the same arena. mmap returns MAP_FAILED with its failure code. Zero-size
heap requests receive a freeable allocation. For calloc multiplication overflow,
`stage=size-overflow` and `bytes=0` indicate that no total size is representable.
The `new` diagnostic family also covers array/aligned/nothrow variants.

`ARBITER_ARENA_RESERVE_BYTES` and `ARBITER_ARENA_SLAB_BYTES` are obsolete and
ignored with a warning. Use a process/cgroup memory limit; canonical full
replays retain `MemoryMax=64G` and `MemorySwapMax=0`. A site may allocate mixed
sizes and alignments, and requests are no longer limited to half a chunk.

jemalloc statistics supply allocation/free/live counts and current usable
`allocated_bytes` (requires jemalloc's stats-enabled build when reporting).
`object_bytes` is the first requested size, or zero if that site saw mixed
sizes. `assigned_bytes` counts mappings obtained through the extent hooks,
including retained capacity and arena metadata, not RSS. Historical
`peak_live`, cumulative requested/slot bytes and failure-category counters
are no longer emitted; legacy CSV capacity/peak columns are left empty.
`fallback_allocations=0` is retained for report compatibility: allocation
fallback no longer exists, and this field is not a failed-allocation counter.

`resident_bytes` and per-node counts include private resident pages located
by `move_pages` after `mincore` filtering. Read-only kernel zero pages return
`-EFAULT`; after confirming the mapping still exists, the report counts them
separately as `zero_pages`, not as private NUMA memory. Other query failures
remain errors. A valid comparison requires zero fallbacks/query errors and
all located pages on the requested node. Live-object tests independently
write and verify object pages on both Local and CXL nodes.

Only extent ranges are tracked for ownership. The per-object live bitmap and
page-owner table are removed. Invalid/interior/double frees now have the same
undefined behavior as ordinary `free`; use allocator/sanitizer diagnostics.
Extents remain mapped for jemalloc reuse until process exit, although purging
can release their physical pages. This also keeps ownership lookup safe from
unmap/reuse races during rewritten static destructors.

## Build and Inspect

The default build uses the recommended retained policy:

```sh
./scripts/build-xindex-llvm.sh
```

Select another measured candidate with:

```sh
ARBITER_HITM_SEED_CONFIG=configs/hitm-seed/candidates/raw-082.config \
  ./scripts/build-xindex-llvm.sh
```

Each build retains:

```text
ycsb_bench.sites.csv
ycsb_bench.hitm-seed-sites.csv
ycsb_bench.hitm-seed-effective.opt-args
```

Site IDs are stable for the same source, compiler, and optimization settings,
but may change when any of them changes. Retained configs therefore express
scores and gates rather than pinning a site ID.

## Result Labels

```text
native
hitm-seed-local
hitm-seed-target
```

Local and target rows use the same rewritten binary and arena code. Only the
arena node differs. The protected driver rejects missing reports, fallback,
placement-query errors, wrong residency, nonzero exit status, and mismatched
expected seed counts.

For the exact run command, cache policy, result files, and retained numbers,
see [XIndex/YCSB-A Result](results/xindex-ycsb-a.md).
