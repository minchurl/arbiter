# 2026-10-08 `raw-046` One-Pass Result

This directory preserves the machine-readable summary for the canonical
four-pair XIndex/YCSB-A run. Every row consumed the complete 400M-operation
transaction trace once and exited; no duration cutoff or cyclic replay was
used.

## Setup

- Trace: YCSB A, 100M load records and 400M transaction operations
- Workers: 31 foreground and one background worker
- CPU/general memory: node 0
- Compared arena placement: node 0 local versus node 2 CXL
- Order: alternating Local/CXL across four pairs
- Protection: `MemoryMax=64G`, `MemorySwapMax=0`
- Arena: strict mode, 2MiB slabs, 24GiB reserve, 64-byte alignment
- Cache policy: fresh process per row, warm filesystem page cache
- Git commit: `5cc711bf2b6172432631ef3e618ee847276e3f30`

## Result

| Repeat | Local | CXL | CXL vs local |
|---:|---:|---:|---:|
| 1 | 26.423M op/s | 49.276M op/s | +86.49% |
| 2 | 26.094M op/s | 49.661M op/s | +90.31% |
| 3 | 27.360M op/s | 48.527M op/s | +77.36% |
| 4 | 26.248M op/s | 48.806M op/s | +85.94% |

Mean throughput was **26.531M local** versus **49.068M CXL op/s**. The mean
paired improvement was **+85.03%**.

All eight rows completed successfully. Each row reported 52,791,182 arena
allocations, 17.310GiB resident on the requested node, zero fallback, zero
swap, and zero placement-query errors. Mean max RSS was 30.196GiB.

## Files

- `runs.csv`: row-level throughput, memory, placement, and safety counters
- `summary.csv`: four-row mean for each placement
- `manifest.txt`: execution contract, policy hash, machine NUMA topology, and
  tool paths

This result establishes a repeatable placement-associated throughput
difference for this binary, trace, and machine. It does not by itself prove a
HITM reduction; that requires hardware counters and correctness checks.
