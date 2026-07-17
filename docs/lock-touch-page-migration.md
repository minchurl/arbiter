# Lock-Touch Page Migration

Lock-touch page migration is an LLVM-only Arbiter experiment for lock-heavy
shared mutable data. It instruments synchronization target addresses instead
of allocation sites, then lets the runtime sample those touches and optionally
migrate the containing page to `ARBITER_TARGET_NODE`.

This experiment is intentionally separate from allocation-site placement. It
does not replace locks or atomics, and it does not move a whole allocation just
because the allocation contains a lock.

## Passes

```text
arbiter-report-lock-touch-sites
arbiter-experiment-lock-touch-instrument
```

Options:

```text
-arbiter-lock-touch-report-path=<path>
```

The report pass emits:

```text
site_id,function,file,line,kind,target
```

The instrument pass inserts:

```c
void arbiter_lock_touch(void *addr, uint32_t site_id);
```

immediately before each recognized synchronization operation.

## Recognized Sites

The first pass instruments these targets:

- `pthread_mutex_lock(ptr)`
- `pthread_mutex_trylock(ptr)`
- `pthread_rwlock_rdlock(ptr)`
- `pthread_rwlock_wrlock(ptr)`
- `pthread_spin_lock(ptr)`
- `atomicrmw` target pointer
- `cmpxchg` target pointer
- atomic store target pointer
- first pointer operand of inline assembly containing `lock` or `cmpxchg`

It deliberately skips pthread unlock calls, ordinary stores, volatile-only
stores, and fences such as `mfence`.

The inline assembly rule is needed for XIndex, whose custom lock helpers lower
to IR shaped like:

```llvm
call i64 asm sideeffect "lock; cmpxchgq $2,$1", ...
```

## Runtime Modes

`arbiter_lock_touch` has a cheap sampled fast path and a page-table slow path.

Environment variables:

```text
ARBITER_LOCK_TOUCH_MODE=auto|off|touch|migrate
ARBITER_LOCK_TOUCH_SAMPLE_PERIOD=<n>   default: 1024
ARBITER_LOCK_TOUCH_THRESHOLD=<n>       default: 64 sampled touches
ARBITER_TARGET_NODE=<node>
```

Mode behavior:

- `auto`: migrate when `ARBITER_TARGET_NODE` is set, otherwise touch-only
- `off`: return immediately
- `touch`: sample and count pages, but do not migrate
- `migrate`: after threshold, attempt one `move_pages` migration per page

Migration is page-based. The runtime aligns `addr` down to the containing page,
tracks sampled touches in a sharded table, and attempts one `move_pages` call
with `MPOL_MF_MOVE` after the threshold. If `numaif.h`/`move_pages` support is
not available at build time, migration is disabled and touch counting still
builds.

## XIndex Usage

Build the lock-touch variant with:

```sh
./scripts/build-xindex-lock-touch-llvm.sh
```

Inspect the site report:

```text
build/arbiter-bench/xindex/ycsb_bench.lock-touch-sites.csv
```

The generic XIndex build harness still supports the equivalent explicit form:

```sh
ARBITER_XINDEX_EXPERIMENT=lock-touch ./scripts/build-xindex-llvm.sh
```

Run modes with the existing XIndex runner:

```sh
./scripts/run-xindex-arbiter.sh native
ARBITER_LOCK_TOUCH_MODE=off ./scripts/run-xindex-arbiter.sh local
ARBITER_LOCK_TOUCH_MODE=touch ./scripts/run-xindex-arbiter.sh local
ARBITER_LOCK_TOUCH_MODE=migrate ARBITER_TARGET_NODE=<node> \
  ./scripts/run-xindex-arbiter.sh remote
```

The disabled and touch-only modes isolate instrumentation overhead from the
page migration policy.

## Limitations

- Migration is page-granular, not cache-line-granular.
- Other data on the same page moves with the lock-like word.
- The runtime's page table is keyed by virtual page address and is not tied to
  object lifetime. If a lock-bearing object is freed and the same page address
  is later reused for unrelated data, stale sampled-touch or migration-attempt
  state may affect the new occupant. This should not affect program
  correctness because the hook is advisory, but it can add experiment-policy
  noise.
- `move_pages` can be expensive and may fail due to system policy or
  permissions.
- The v1 pass instruments all recognized sites; it does not score, filter, or
  rank them.
- Lock abstractions hidden behind unrecognized library calls are not covered.

Possible future mitigation: add a lightweight TTL or epoch to lock-page
migration state so old entries can expire without requiring allocation/free
tracking.
