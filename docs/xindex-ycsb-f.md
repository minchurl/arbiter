# XIndex/YCSB-F

The [initial full-run evidence](../results/xindex/ycsb-f/one-pass-20261022/README.md)
is retained with logs and correctness checks: +45.68% CXL/Local in one
final-code round. Additional rounds are needed for a repeated estimate.

```sh
./scripts/run-xindex-ycsb-f.sh --smoke
./scripts/run-xindex-ycsb-f.sh
```

The default full run uses one native/selected-Local/selected-CXL round. Use
`REPEATS=4 ./scripts/run-xindex-ycsb-f.sh` for four rounds, or `--check` for a
preflight without building or running a benchmark.

## Workload

F is 50% read and 50% read-modify-write. The runner reuses the existing A trace:
READ is unchanged; UPDATE becomes a get followed immediately by put of the
same key, in the same worker. This preserves A's key order, distribution, and
exact mixture without generating another large trace. Explicit
`READMODIFYWRITE usertable user<key> ...` input records are supported too.

This input is either an A trace to reinterpret or a logical F trace with
explicit RMW records. Flattened Java BasicDB F output already contains both
READ and UPDATE calls and must not be passed through the UPDATE-to-RMW mapping.

As in YCSB CoreWorkload, the pair is not an atomic read-modify-write primitive.
The XIndex benchmark uses uint64 values and writes the key as the value, as
its A driver does; it does not increment the previously read value. This is
an index-operation replay, not the complete YCSB Java client/record payload.

Throughput counts **logical transactions/s**: one RMW pair counts once. For
the full A-derived trace there are 400,000,000 logical transactions:

- 199,993,860 read-only transactions;
- 200,006,140 RMW transactions;
- 400,000,000 get calls and 200,006,140 put calls.

Do not compare F's transaction rate with A's as if they performed equal work.
The CSV's legacy `throughput` field and `op/s` display mean logical
transactions/s; exact API call counts are included in each row log.

## Controls and correctness

- Automatic `evidence-balanced-size-tiebreaker.config`, no pinned site IDs.
- Same rewritten binary for Local and CXL, with only the arena node changing.
- 100M load / 400M transactions, one trace pass and no duration cutoff.
- 31 foreground + one background worker; CPUs and ordinary memory on node 0.
- Arena node 0 for Local, node 2 for CXL; strict 24GiB arena.
- MemoryMax=64G and MemorySwapMax=0.
- Fresh process per row; warm filesystem cache, no global cache flush.
- Operation attempts/successes, both RMW sub-call outcomes, placement checks,
  and a deterministic sampled 4,096-key final-state digest.
- Full-run counts and digest must agree across native/Local/CXL. The digest
  samples state; it is not an exhaustive linearizability proof.

Results appear under `build/arbiter-bench/xindex-ycsb-f-<timestamp>/`, including
`runs.csv`, `interpretation.md`, `validation-operations.txt`, and
`validation-digests.txt`. The `replay-manifest.txt` names the input trace and
its UPDATE-to-RMW interpretation.

F changes the workload on XIndex, not the data structure. A positive result
would extend workload coverage but would not establish cross-benchmark
generality. YCSB-B's previous negative results remain in
[the B report](results/xindex-ycsb-b.md).
