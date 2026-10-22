# XIndex/YCSB-F — 2026-10-22

Four full-trace rounds on commit `e14966f`, after per-operation counter removal.
Each row: 100M load records, 400M logical transactions, 31+1 workers, 64GiB cap,
no swap. The automatic evidence-balanced policy was unchanged.

| Round | Native (M tx/s) | Local (M tx/s) | CXL (M tx/s) | CXL/Local |
|---:|---:|---:|---:|---:|
| 1 | 33.091 | 33.821 | 50.826 | +50.28% |
| 2 | 33.584 | 34.904 | 50.151 | +43.68% |
| 3 | 34.779 | 32.748 | 53.630 | +63.77% |
| 4 | 34.476 | 34.342 | 48.117 | +40.11% |

CXL won 4/4 pairs. Ratio of mean throughput: **+49.27% CXL/Local**,
**+49.14% CXL/native**. Complete setup and mean values are in
[the F report](../../../../docs/xindex-ycsb-f.md).

All 12 rows executed 400M transactions; the 4,096-key digest matched
`0x7474b8e9d3962859`. Zero fallback, placement-query errors, or swap;
Local/CXL arena residency: 17.310GiB on the requested node.

- `runs.csv`, `summary.csv`: per-row and mean measurements.
- `logs/`, `console.log`: raw process/timing logs and validation result.
- `replay-manifest.txt`, `hitm-seed-*`: machine, settings, and selected sites.
- `sources.sha256`, `binaries.sha256`: measured source/config and binary hashes.
- `validation-operations.txt`, `validation-digests.txt`: post-timing checks.

Static sites: `68,71,74,90,97,98,99,100`; runtime-active sites: `68,71,74`.
CSV paths retain their original machine locations; copies of every row log are
included in `logs/`. The sampled-state check is not exhaustive validation.
