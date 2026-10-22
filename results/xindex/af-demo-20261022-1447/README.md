# XIndex A/F demo — 2026-10-22

One full-trace Local/CXL pair per workload, with the allocation/delete ABI fixes
retained and extra per-operation success counters removed.

| Workload | Local (M transactions/s) | CXL (M transactions/s) | CXL/Local |
|---|---:|---:|---:|
| A: read/update | 26.593 | 49.304 | +85.41% |
| F: read/read-modify-write | 32.959 | 50.437 | +53.03% |

Each value is one measurement, not a repeated-run average.
Delta: `(CXL / Local - 1) * 100`. The placement benefit remains after the ABI
fixes; this is not a controlled measurement of ABI-fix overhead or hardware HITM.

## Reproduce

```sh
./scripts/run-xindex-a-demo.sh   # Local once, then CXL once
./scripts/run-xindex-f-demo.sh   # Local once, then CXL once
```

Each script sets its policy/workload, builds, runs, and prints measured
throughputs and the percentage change. No arguments or time cutoff.
The archived measurement used one shared build and took about six minutes;
the independent launchers now each build before running the same protocol.

## Conditions and validation

- Benchmark sources: commit `b7b50eb`; only launcher/docs were dirty.
- Automatic `evidence-balanced-size-tiebreaker.config`: size weight +1,
  minimum score 5, no pinned IDs. All four rows used the same binary.
- Each fresh process: 100M load records, one complete 400M-transaction pass,
  31 foreground + one background worker; no cyclic replay or native baseline.
- CPU and ordinary memory: node 0. Arena: node 0 Local / node 2 CXL;
  strict 24GiB arena, 64B slot alignment, `MemoryMax=64G`, swap disabled.
- Warm filesystem cache; no global cache flush or OS/editor cpuset isolation.
- F reuses A's READ/UPDATE trace, interpreting UPDATE as same-worker get/put.
  Each RMW counts once; A/F rates do not represent equal numbers of API calls.
- All four rows: 400M transactions, matching 4,096-key digest
  `0x7474b8e9d3962859`, zero sampled-read failures, swap, arena fallback, or
  placement-query errors. Maximum RSS: 30.196GiB; arena residency: 17.310GiB
  on the requested node. Sampled state is not an exhaustive correctness proof.
- Static sites: `68,71,74,90,97,98,99,100`; runtime sites: `68,71,74`.
  Per row allocations: 26,395,417 / 26,395,622 / 143 respectively.

## Retained evidence

- `runs.csv`: all four measurements; log paths are relative to this directory.
- `logs/`: original process and resource/timing logs for every row.
- `manifest-a.txt`, `manifest-f.txt`: original machine/run settings; trailing
  whitespace normalized, original machine paths retained.
- `hitm-seed-input.config`, `hitm-seed-sites.csv`,
  `hitm-seed-effective.opt-args`: one shared config and compiler report.
- `binaries.sha256`, `benchmark-sources.sha256`,
  `compiler-runtime-binaries.sha256`: benchmark/source/compiler/runtime hashes.

Redundant generated summaries, repeated config/report copies, build-console
output, and empty throughput-sampling CSVs are not retained here. Validation
counts and digests are present in the process logs. No traces or binaries are
duplicated.
