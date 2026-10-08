# XIndex/YCSB-B Result

This result tests whether Arbiter's seed-only placement benefit extends from
write-heavy YCSB-A to read-heavy YCSB-B. The run rebuilt the same frozen
100-config search space with the current compiler and executed one complete
400M-operation YCSB-B trace per process.

## Setup

| Control | Value |
|---|---|
| Load input | 100M-record YCSB-A load trace |
| Transactions | 400M YCSB-B operations |
| Workload mix | approximately 95% reads, 5% updates |
| Workers | 31 foreground, 1 background |
| CPU / ordinary memory / CXL | node 0 / node 0 / node 2 |
| Arena | strict, 2MiB slabs, 24GiB reserve, 64B alignment |
| Process protection | `MemoryMax=64G`, `MemorySwapMax=0` |
| Execution | fresh process; one full transaction-trace pass |
| Filesystem cache | warm; no `drop_caches` |

The local and CXL rows for a candidate used the same rewritten binary and
allocator. Only the arena NUMA node changed. Local/CXL order alternated across
pairs.

## Candidate Processing

All 100 archived parameter inputs were evaluated:

| Disposition | Count |
|---|---:|
| Static-unique safe policies screened | 21 |
| Static duplicates | 62 |
| Non-constant-size selections rejected | 12 |
| No selected site | 4 |
| Build failure | 1 |

The run recorded 42 screening rows for the 21 local/CXL pairs, plus four
native rows for each of YCSB-A and YCSB-B. Six screened policies performed no
runtime arena allocation and were excluded rather than interpreted as CXL
results.

## Result

Fifteen local/CXL pairs passed all runtime comparability checks:

- both processes completed successfully;
- identical, nonempty runtime allocation-site fingerprints;
- zero swap, arena fallback, and placement-query errors;
- arena residency on the requested NUMA nodes;
- nonzero measured throughput.

Every valid candidate regressed with CXL. Paired CXL-over-local throughput
deltas ranged from **-19.18% to -45.34%**. No candidate crossed the -15%
promotion threshold, so multi-pair confirmation and the planned final A/B
stage did not run.

The four native YCSB-B rows averaged 99.16 M op/s. No row encountered OOM or
used swap, and maximum RSS was approximately 33.3 GiB under the 64 GiB hard
limit.

## Interpretation

For this XIndex/YCSB-B setup, moving selected objects to CXL did not improve
throughput. With only about 5% updates, the measured coherence benefit was not
large enough to offset added CXL access cost.

This is a workload-level boundary for the positive YCSB-A result, not a
general claim about every read-heavy workload. Each candidate was screened
with one local/CXL pair, so the uniform negative direction is useful evidence,
but the exact regression of an individual candidate is not a confirmed effect
size.

## Reproduce and Inspect

The frozen inputs are under
[`configs/hotset/search-spaces/xindex-broad-100/`](../../configs/hotset/search-spaces/xindex-broad-100/README.md).
Validate the runner without building or benchmarking:

```sh
./scripts/run-xindex-ycsb-b-adaptive-sweep.sh --check
```

Start a fresh run with:

```sh
./scripts/run-xindex-ycsb-b-adaptive-sweep.sh --run
```

The reportable outputs from the completed run are retained under
[`results/xindex/ycsb-b/fulltrace-sweep-20261008/`](../../results/xindex/ycsb-b/fulltrace-sweep-20261008/README.md).
