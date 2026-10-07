# HITM-Risk Seed Placement

Arbiter selects allocation sites at compile time and places allocations from
those sites into a NUMA-bound runtime arena. “Hot-set migration” is the
historical experiment name; the current runtime places new objects and never
migrates an already allocated object.

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
The fixed-slot arena needs a stable size/alignment per site, so every retained
XIndex policy sets it to zero.

## Static Byte Budget

`ARBITER_HOTSET_DYNAMIC_SIZE_ESTIMATE` is the accounting size for a selected
dynamic allocation. `ARBITER_HOTSET_MAX_ESTIMATED_BYTES` caps the sum of
selected estimates; zero means unlimited. Exceeding a nonzero budget aborts
compilation rather than silently changing the selected set.

This is only a static guard. Runtime allocation count and live bytes determine
the actual arena footprint and must be read from the arena report.

## Arena Placement

The arena reserves a virtual range with `MAP_NORESERVE`, binds it to
`ARBITER_TARGET_NODE`, and assigns fixed-size slabs to each `(site, size,
alignment)` tuple. Untouched reservation space does not contribute to RSS.

| Runtime variable | Replay value | Meaning |
|---|---:|---|
| `ARBITER_HEAP_BACKEND` | `arena` | packed slab allocator |
| `ARBITER_ARENA_SLAB_BYTES` | 2097152 | 2MiB slab size |
| `ARBITER_ARENA_RESERVE_BYTES` | 25769803776 | 24GiB virtual capacity |
| `ARBITER_ARENA_SLOT_ALIGNMENT` | 64 | minimum slot alignment |
| `ARBITER_ARENA_STRICT` | 1 | prohibit direct fallback |
| `ARBITER_ARENA_REPORT` | 1 | emit allocation and residency counters |

At process exit the runtime reports per-site allocation counts, assigned and
resident bytes, fallback counts, and resident pages by NUMA node. A valid
comparison requires zero fallback and query errors and the expected majority
node for both local and CXL rows.

## Build and Inspect

The default build uses the recommended retained policy:

```sh
./scripts/build-xindex-llvm.sh
```

Select another measured candidate with:

```sh
ARBITER_HOTSET_CONFIG=configs/hotset/candidates/raw-082.config \
  ./scripts/build-xindex-llvm.sh
```

Each build retains:

```text
ycsb_bench.sites.csv
ycsb_bench.hotset-sites.csv
ycsb_bench.hotset-effective.opt-args
```

Site IDs are stable for the same source, compiler, and optimization settings,
but may change when any of them changes. Retained configs therefore express
scores and gates rather than pinning a site ID.

## Result Labels

```text
native
hotset-seed-local
hotset-seed-target
```

Local and target rows use the same rewritten binary and arena code. Only the
arena node differs. The protected driver rejects missing reports, fallback,
placement-query errors, wrong residency, nonzero exit status, and mismatched
expected seed counts.

For the exact run command, cache policy, result files, and retained numbers,
see [XIndex Hot-Set Experiment](experiments/xindex-hotset.md).
