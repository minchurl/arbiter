# Shared-Mutable Pattern Placement

This document describes a generic LLVM-only placement experiment for Arbiter.
It is separate from benchmark-calibrated experiments such as XIndex/YCSB
pattern placement.

The goal is to score heap allocation sites using general static signals that
suggest shared mutable coherence pressure. The pass does not use benchmark
names, source filenames, hardcoded line ranges, or function-name penalties such
as model/train/load/init.

## Hypothesis

An allocation is a stronger placement candidate when:

- a pointer derived from the allocation escapes the local function,
- synchronization-style mutation appears near the allocation, and
- the allocation is inside or reachable from a pthread worker path.

The pass is intentionally conservative. A large allocation alone is not enough.
An escaped allocation alone is not enough. Selection requires both an escape
signal and a sync/mutable signal.

## Passes

```text
arbiter-report-shared-mutable-sites
arbiter-experiment-shared-mutable-rewrite
```

Options:

```text
-arbiter-shared-mutable-report-path=<path>
-arbiter-shared-mutable-min-score=<n>
```

The report pass emits:

```text
site_id,kind,function,file,line,callee,size_expr,score,selected,reasons
```

The rewrite pass selects heap allocation sites whose score is at least the
threshold and that have both escape and sync/mutable signals. It then reuses the
existing heap rewrite path and side-table-aware deallocation helpers.

## Static Signals

Escape signals:

- allocation-derived pointer returned from the function,
- allocation-derived pointer stored to memory,
- allocation-derived pointer passed to a non-deallocation, non-intrinsic call.

Sync/mutable signals:

- `atomicrmw` or `cmpxchg` in the same function,
- atomic or volatile store in the same function,
- inline assembly containing `lock` or `cmpxchg` in the same function,
- synchronization-style mutation in the same debug source file.

Thread-sharing signals:

- allocation in a `pthread_create` start routine,
- allocation in a function directly reachable from such a start routine.

Size signal:

- dynamic allocation size,
- constant allocation size of at least 4096 bytes.

## XIndex Use

For XIndex, build the generic experiment with:

```sh
ARBITER_XINDEX_EXPERIMENT=shared-mutable ./scripts/build-xindex-llvm.sh
```

Then inspect:

```text
build/arbiter-bench/xindex/ycsb_bench.shared-mutable-sites.csv
```

The purpose is first to see whether generic static signals rank known
coherence-sensitive XIndex candidates near the top. This pass should not be
treated as the same claim as an XIndex/YCSB-specific calibrated selector.

## Limitations

This is not field-sensitive points-to analysis and it does not identify exact
hot keys or hot groups. It does not know which object is mutated after escape.
False positives are expected, so the report is part of the experiment rather
than just debug output.
