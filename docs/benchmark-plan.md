# Benchmark Plan

This document describes how Arbiter's LLVM-only path targets GUPS and
XIndex/YCSB.

## Measurement Modes

Every benchmark should be run in three modes:

```text
native baseline
instrumented local fallback
instrumented remote target node
```

Use `ARBITER_TARGET_NODE` only for the remote placement mode.

## GUPS

GUPS allocates its primary data region with anonymous `mmap`, not `malloc`.
Therefore a malloc-only pass cannot place the important object.

The first LLVM-only experiment uses `arbiter-experiment-all-rewrite`, so every
supported anonymous mmap and heap allocation site is instrumented. This is a
coarse baseline for validating the runtime path before adding narrower
experiment passes.

The existing GUPS size arguments remain the source of truth for experiment
scale.

## XIndex/YCSB

XIndex allocates important index structures through C++ heap allocation paths.
The LLVM pass must support C++ `new`/`delete` ABI forms and `std::malloc`.

Important future placement candidates:

- `HGroup::data_array`
- `AltBtreeBuffer::allocate_new_block`
- root and group allocations

Future narrower experiment passes should avoid moving:

- YCSB operation queue
- trace-loading vectors
- model-training temporary buffers

The YCSB benchmark should accept input paths from the command line:

```text
--ycsb-load benchmark/xindex/YCSB/xindex_dat/xindex_load_ycsb_a.dat
--ycsb-tx benchmark/xindex/YCSB/xindex_dat/xindex_transaction_ycsb_a.dat
```

The benchmark size should be determined by the input files. The implementation
should not assume hardcoded operation or key counts.

## Scripts

```text
scripts/collect-allocation-sites.sh
scripts/build-gups-llvm.sh
scripts/build-xindex-llvm.sh
scripts/run-gups-arbiter.sh
scripts/run-xindex-arbiter.sh
```

The build scripts generate LLVM bitcode, run the Arbiter LLVM plugin, and link
instrumented benchmark binaries.
