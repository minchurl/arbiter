# XIndex/YCSB Pattern Placement

This note documents the XIndex/YCSB placement experiment for Arbiter's LLVM
path. The goal is not to move every shared object. The goal is to select
allocation sites that are likely to back shared mutable cache lines under
YCSB-A.

## XIndex and YCSB

XIndex is a learned key-value index. A root model routes a key to an `HGroup`.
The group predicts a bucket in `data_array`. If the key is there, the operation
reads or updates the bucket's `AtomicVal`. If the bucket has a conflict, XIndex
uses an `AltBtreeBuffer` chain.

```text
XIndex -> HRoot -> HGroup -> data_array[pos]
                         -> AltBtreeBuffer chain
```

YCSB is a key-value workload generator. In this benchmark, YCSB traces are read
into an operation queue. Foreground workers split that queue by index range, not
by key range. With a Zipfian trace, the same hot keys can appear in multiple
worker ranges and all workers call `get`, `put`, or `remove` on the same XIndex
table.

## Observation

YCSB-A is the primary target:

```text
read 50%
update 50%
requestdistribution zipfian
```

This creates repeated updates to hot keys. The mutable lines behind
`AtomicVal::status/value` and buffer leaf `locked/version/vals` can move between
cores and create coherence pressure. Prior observation says that moving part of
the data to CXL-like memory can improve YCSB-A.

YCSB-B is the comparison workload:

```text
read 95%
update 5%
requestdistribution zipfian
```

It still has hot keys, but most accesses are reads. The same placement effect
should be weak or absent. If YCSB-B improves strongly, the hypothesis should be
revisited because read-path metadata placement may be dominating.

## Target Objects

The v1 compiler experiment uses static, explainable scoring. It does not use
profiling and it does not identify individual hot keys or hot groups.

High-score targets:

- `AltBtreeBuffer::allocate_new_block`: allocates buffer node blocks. These
  nodes contain `locked`, `version`, and leaf `vals`.
- `HGroup::data_array`: allocates primary group records. Records contain `key`,
  `AtomicVal`, and the conflict-chain pointer.

Non-targets:

- root, group pointer array, and models: mostly read-shared metadata.
- YCSB operation queue and trace-loading buffers: read-only or setup data.
- model-training temporary allocations: not foreground hot-path data.
- RCU status slots: close to per-worker writes.

## Compiler Experiment

Arbiter adds two pattern passes:

```text
arbiter-report-pattern-sites
arbiter-experiment-pattern-rewrite
```

The report pass emits allocation site scores and reasons. The rewrite pass
selects heap allocation sites whose score is at least
`-arbiter-pattern-min-score` and rewrites only those sites to Arbiter runtime
calls. Deallocation is still rewritten through side-table-aware `*_maybe`
helpers when a selected allocation exists.

The XIndex build script keeps all-rewrite as the default. Use the pattern
experiment explicitly:

```sh
ARBITER_XINDEX_EXPERIMENT=pattern ./scripts/build-xindex-llvm.sh
```

## Experiment Matrix

Run both YCSB-A and YCSB-B:

```text
native
instrumented local fallback
all-rewrite remote
pattern-rewrite remote
```

Expected interpretation:

- YCSB-A should show the strongest placement effect.
- YCSB-B should show little or no improvement.
- Pattern rewrite should be easier to interpret than all-rewrite because trace
  buffers, model temporaries, and read-mostly metadata are left local.

The first pattern result is a compiler-assisted experiment, not a general proof
that static analysis can always find hot keys. Hot-group placement requires a
future runtime-conditional or profile-guided mechanism because all groups share
the same `data_array` allocation site.
