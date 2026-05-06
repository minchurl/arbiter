# SCF Parallel Store Heuristic Experiment

Branch: `experiments/scf-parallel-store-heuristic`

This document describes an experimental object-selection policy for Arbiter. The
goal is to replace the previous prototype behavior, which selected every
`memref.alloc`, with a narrow static heuristic that selects only allocation-backed
objects that have a strong local signal for both write intensity and sharing.

This is an experiment. It is not intended to be a complete static analysis, and
it should not be treated as a performance guarantee.

## Background

Arbiter separates object selection from allocation rewriting.

The selection pass decides which allocation-backed objects should be placed on
the configured Arbiter target memory node. In the current compiler pipeline, the
selection result is represented by the `arbiter.select` unit attribute on a
`memref.alloc` operation:

```mlir
%a = memref.alloc(%n) {arbiter.select} : memref<?xi32>
```

Later rewrite passes consume this attribute:

```text
memref.alloc {arbiter.select}
  -> arbiter.alloc
  -> arbiter_alloc(...)

memref.dealloc of the selected object
  -> arbiter.dealloc
  -> arbiter_dealloc(...)
```

At runtime, `arbiter_alloc` places selected objects on the memory node configured
by `ARBITER_TARGET_NODE` when that node is available.

The first prototype selected every `memref.alloc`. That was useful for validating
the rewrite and runtime plumbing, but it is too broad for the actual Arbiter
hypothesis. The next step is to select only objects that plausibly match the
write-heavy and sharable object profile.

## Hypothesis

The experimental hypothesis is:

```text
An allocation-backed memref object that is stored to inside an scf.parallel
region is likely to be both write-heavy and sharable.
```

This combines two local signals:

1. `memref.store` means the object is written.
2. Nesting inside `scf.parallel` means the write is part of a parallel execution
   region, so the object may be accessed by multiple workers.

Together, these signals identify objects that are more likely to suffer from
coherence and contention effects than objects that are only read, written once,
or written only in serial code.

The heuristic is intentionally conservative. It prefers missing some possible
candidates over selecting many unrelated allocations.

## Selection Rule

Version 1 of this experiment uses one rule:

```text
Select a memref.alloc if any direct user of the alloc result is a memref.store
and that memref.store is nested inside an scf.parallel operation.
```

In pseudocode:

```text
for each memref.alloc:
  for each direct user of alloc.result:
    if user is memref.store and user is inside scf.parallel:
      add arbiter.select to the memref.alloc
```

The current experiment only follows direct uses of the `memref.alloc` result.
For example, it handles this:

```mlir
%a = memref.alloc(%n) : memref<?xi32>
scf.parallel (%i) = (%c0) to (%n) step (%c1) {
  memref.store %value, %a[%i] : memref<?xi32>
  scf.reduce
}
```

It does not yet follow view-like aliases such as `memref.subview`,
`memref.cast`, or `memref.reinterpret_cast`.

## Positive Example

This object should be selected:

```mlir
func.func @parallel_store(%n: index, %value: i32) {
  %c0 = arith.constant 0 : index
  %c1 = arith.constant 1 : index

  %hist = memref.alloc(%n) : memref<?xi32>

  scf.parallel (%i) = (%c0) to (%n) step (%c1) {
    memref.store %value, %hist[%i] : memref<?xi32>
    scf.reduce
  }

  memref.dealloc %hist : memref<?xi32>
  return
}
```

After object selection:

```mlir
%hist = memref.alloc(%n) {arbiter.select} : memref<?xi32>
```

After allocation rewriting:

```mlir
%hist = arbiter.alloc(%n) : memref<?xi32>
```

The object is selected because the allocation result `%hist` is directly used by
a `memref.store` nested inside `scf.parallel`.

## Negative Example: Parallel Load Only

This object should not be selected:

```mlir
func.func @parallel_load_only(%n: index) {
  %c0 = arith.constant 0 : index
  %c1 = arith.constant 1 : index

  %input = memref.alloc(%n) : memref<?xi32>

  scf.parallel (%i) = (%c0) to (%n) step (%c1) {
    %value = memref.load %input[%i] : memref<?xi32>
    scf.reduce
  }

  memref.dealloc %input : memref<?xi32>
  return
}
```

The object is accessed in parallel, but there is no parallel store to the object.
This does not match the write-heavy part of the hypothesis.

## Negative Example: Serial Store

This object should not be selected:

```mlir
func.func @serial_store(%n: index, %value: i32) {
  %c0 = arith.constant 0 : index

  %scratch = memref.alloc(%n) : memref<?xi32>
  memref.store %value, %scratch[%c0] : memref<?xi32>

  memref.dealloc %scratch : memref<?xi32>
  return
}
```

The object is written, but the write is not nested inside an `scf.parallel`
region. This does not match the sharable part of the hypothesis.

## Negative Example: View Alias Not Tracked Yet

This object is a plausible candidate, but this heuristic does not select it:

```mlir
func.func @parallel_store_through_subview(%n: index, %value: i32) {
  %c0 = arith.constant 0 : index
  %c1 = arith.constant 1 : index

  %a = memref.alloc(%n) : memref<?xi32>
  %view = memref.subview %a[0] [%n] [1]
      : memref<?xi32> to memref<?xi32, strided<[1], offset: ?>>

  scf.parallel (%i) = (%c0) to (%n) step (%c1) {
    memref.store %value, %view[%i]
        : memref<?xi32, strided<[1], offset: ?>>
    scf.reduce
  }

  memref.dealloc %a : memref<?xi32>
  return
}
```

This is not selected because the `memref.store` uses `%view`, not the original
allocation result `%a`. Handling this case requires alias or view tracking and is
left for a later experiment.

## Why This Heuristic

The full problem is harder than the version 1 rule.

Accurate write-heavy detection may require loop trip counts, access frequency,
dynamic profiling, operation weighting, and knowledge of whether stores target
the same cache lines.

Accurate sharing detection may require interprocedural escape analysis, task
mapping, thread ownership reasoning, and alias analysis across memref view-like
operations.

This experiment starts with a signal that is:

- visible at memref-level MLIR,
- cheap to compute,
- easy to test with FileCheck,
- directly connected to Arbiter's write-heavy and sharable object hypothesis,
- narrow enough to avoid selecting every allocation.

## Expected Workload Shape

This heuristic is expected to match code shapes such as:

```c
parallel_for (i = 0; i < n; ++i) {
  bucket = input[i] % num_buckets;
  hist[bucket] += 1;
}
```

or:

```c
parallel_for (i = 0; i < n; ++i) {
  counters[keys[i]] += deltas[i];
}
```

The important property is not merely that the program writes often. The more
interesting case for Arbiter is when multiple workers repeatedly write to a
shared object or to nearby locations that can create cache-line ownership
traffic.

Matrix multiplication can match the syntactic rule if the output matrix is
stored inside a parallel region:

```c
parallel_for (i = 0; i < n; ++i) {
  for (j = 0; j < n; ++j) {
    C[i][j] = dot(A[i], B_column[j]);
  }
}
```

However, this may be a weaker performance target for Arbiter if each worker owns
disjoint rows or tiles of `C`. In that case, the object is write-heavy, but the
coherence contention may be lower than in histogram or counter-style updates.

## Test Intent

The smoke tests for this experiment should validate compiler behavior, not
runtime speed.

They should check that:

1. A direct `memref.store` inside `scf.parallel` selects the allocation.
2. A parallel load-only object is not selected.
3. A serial store is not selected.
4. Allocation rewriting only rewrites selected objects.
5. Runtime lowering still sees selected objects after the selection and rewrite
   pipeline.

Performance experiments should be separate from this compiler smoke test.

## Known Limitations

This version intentionally does not handle:

- stores through `memref.subview`,
- stores through `memref.cast`,
- stores through `memref.reinterpret_cast`,
- stores through function calls,
- stores through unknown dialect operations,
- distinguishing disjoint per-thread writes from contended writes,
- measuring actual write intensity,
- detecting false sharing at cache-line granularity,
- interprocedural sharing or escape analysis.

These limitations are acceptable for the first experiment because the goal is to
move from selecting every allocation to selecting only objects with a strong and
locally visible parallel-write signal.

## Possible Follow-up Experiments

Future versions can extend the policy in small steps:

1. Track simple view-like memref aliases.
2. Treat stores inside `scf.for` nested below `scf.parallel` as parallel stores.
3. Add a loop-weighted write score.
4. Add conservative escape detection for function calls and returns.
5. Add a manual override attribute for experiment control.
6. Compare static selection results against hardware performance counters.

Each follow-up should preserve the same output contract: selected allocation
objects are marked with `arbiter.select`, and the allocation rewrite pipeline
continues to consume only that attribute.
