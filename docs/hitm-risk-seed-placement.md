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
binding one 4 KiB page per object would require 1.36 GiB. The direct backend
also records each pointer in an ownership hash table.
[Site-99 measurements](history/hotset-results.md)

The jemalloc backend keeps that packing and placement contract. It binds one
anonymous reservation with `mbind(MPOL_BIND)` before any page is touched. Each
active site gets an explicit jemalloc arena whose extent hooks supply memory
only from the reservation. jemalloc splits, merges and reuses extents. Both
allocation and deallocation bypass the thread cache to preserve placement
across sites and ordinary heap traffic. [jemalloc arena API](https://jemalloc.net/jemalloc.3.html)

| Runtime variable | Replay value | Meaning |
|---|---:|---|
| `ARBITER_HEAP_BACKEND` | `arena` | NUMA-bound jemalloc arenas |
| `ARBITER_ARENA_SLAB_BYTES` | 2097152 | reserve rounding unit and retained-growth limit. Maximum alignment-rounded request is half this value |
| `ARBITER_ARENA_RESERVE_BYTES` | 25769803776 | 24GiB virtual capacity |
| `ARBITER_ARENA_SLOT_ALIGNMENT` | 64 | minimum slot alignment |
| `ARBITER_ARENA_STRICT` | 1 | prohibit direct fallback |
| `ARBITER_ARENA_REPORT` | 1 | emit allocation and residency counters |

The reserve caps virtual extent space across all sites, including jemalloc
arena metadata, retained capacity and alignment gaps. Small reserves can fill
before the requested payload reaches the cap. Untouched virtual pages consume
no arena RSS. `slot_bytes` is jemalloc's usable size for the aligned request.
`assigned_bytes` sums bytes handed to jemalloc by the extent hooks.
`resident_bytes` measures physical pages with `mincore` and the per-node counts
come from `move_pages`. The runtime's ownership bitmap and page-to-site table
live outside the bound range and contribute to process RSS. A valid comparison
requires zero fallbacks and query errors and the expected majority node for
both local and CXL rows.

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
