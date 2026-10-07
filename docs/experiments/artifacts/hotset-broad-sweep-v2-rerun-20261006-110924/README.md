# 2026-10-06 Completed Full-Trace Broad Sweep

This directory preserves the bounded, text-only aggregate evidence from the
successful rerun at:

```text
/home/shin/arbiter/build/arbiter-bench/
  hotset-broad-sweep-v2-rerun-20261006-110924/
```

The run used commit `fff0b32ce677c95d595b492b83cd3cc91eded59d`, the
100M-load/400M-transaction YCSB A traces, 31 foreground plus one background
worker, CPU/local node 0, CXL node 2, strict fixed-slot arenas, `MemoryMax=64G`,
and zero swap. It started at 2026-10-06 11:19:30 KST and completed normally at
16:58:53 KST.

## Completion and Safety

- Final controller status: `complete`
- Controller parse failures: 0
- Fresh-process rows: 131
- Statuses: 123 `ok`, 8 `arena-report-missing`
- OOM, timeout, swap, fallback, and placement-query errors: 0
- Maximum RSS: 34,880,388 KiB (33.26 GiB)
- Maximum CXL-resident arena: 20,275,609,600 bytes (18.88 GiB)
- Native anchors: 27.9994M, 28.1054M, and 27.4271M op/s

The eight missing arena reports were four screen pairs whose statically
selected sites did not allocate at runtime. They were excluded from promotion
and were not benchmark crashes.

## Final-Stage Result

The controller's `final-summary.csv` combines one 15-second screen pair, two
60-second confirmation pairs, and four 180-second final pairs. For a
duration-homogeneous view, `final-stage-only-summary.csv` recomputes the result
from only the four 180-second pairs:

| Candidate | Runtime sites | Local | CXL | Mean paired delta | CXL wins | CXL resident |
|---|---|---:|---:|---:|---:|---:|
| `raw-043` | `21+37+68+69+71+74` | 27.656M | 57.345M | +107.68% | 4/4 | 18.88 GiB |
| `raw-046` | `68+71+74` | 27.886M | 56.813M | +103.75% | 4/4 | 17.31 GiB |
| `raw-021` | `68+69+71+74` | 28.484M | 57.103M | +100.47% | 4/4 | 18.88 GiB |
| `raw-013` | `68+69+71` | 28.086M | 55.786M | +98.63% | 4/4 | 18.88 GiB |
| `raw-082` | `71` | 28.801M | 44.896M | +55.86% | 4/4 | 14.16 GiB |

All five finalists also won all seven pairs when the shorter promotion phases
were included. Candidate `raw-043` has the highest paired percentage, but one
unusually low local row contributes to that rank. `raw-046` reaches nearly the
same absolute CXL throughput with less resident CXL memory. `raw-021` has the
lowest final-stage paired-delta standard deviation. `raw-082` is the simplest
automatic result: compiler-selected seed site 71 only.

## Files

- `manifest.txt`: immutable run shape, paths, versions, and completion status
- `candidates.csv`: build/filter disposition of all 100 generated configs
- `selected-candidates.csv`: 18 statically unique screen candidates
- `observations.csv`: all 131 process-level measurements and placement checks
- `throughput-samples.csv`: within-process interval throughput samples
- `phase1-*`, `phase2-*`, `final-*`: controller summaries and rankings
- `final-stage-only-summary.csv`: recomputed homogeneous 180-second result
- `native-summary.csv`: start/middle/end drift anchors
- `configs/`: finalists plus the site-68 diagnostic candidate `raw-036`

Per-row binaries, full logs, and the 27 GB raw traces remain outside git. The
aggregate files retain absolute paths to the original result tree for local
cross-checking.

## Claim Boundary

This run establishes a repeatable placement/throughput signal and validates
the tested 64G safety envelope. It does not yet establish that reduced HITM is
the cause. The benchmark did not collect HITM/C2C counters or p99 latency, and
its throughput counter does not validate `get`/`put` return values or a final
data checksum. Those checks are required before treating the magnitude as a
correctness-validated mechanism result.
