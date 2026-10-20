# 2026-10-20 XIndex Site Ablation

This directory retains the compact comparison derived from the four-policy
XIndex/YCSB-A site-ablation run. Every row consumed the complete 400M-operation
transaction trace once; each policy ran four alternating Local/CXL pairs.

## Setup

- Trace: YCSB A, 100M load records and 400M transaction operations
- Workers: 31 foreground and one background worker
- CPU/general memory: node 0
- Compared arena placement: node 0 local versus node 2 CXL
- Protection: `MemoryMax=64G`, `MemorySwapMax=0`
- Arena: strict mode, 2MiB slabs, 24GiB reserve, 64-byte alignment
- Cache policy: fresh process per row, warm filesystem page cache
- Git commit at execution: `e3af633e`

## Result

| Policy | Runtime sites | Local | CXL | Mean paired delta | CXL resident |
|---|---|---:|---:|---:|---:|
| Site 68 only | `68` | 26.893M op/s | 39.367M op/s | +46.35% | 3.147GiB |
| Site 71 only | `71` | 26.924M op/s | 40.597M op/s | +50.78% | 14.163GiB |
| Sites 68+71 | `68,71` | 26.290M op/s | 50.092M op/s | +90.79% | 17.310GiB |
| raw-046 | `68,71,74` | 26.287M op/s | 50.324M op/s | +91.53% | 17.310GiB |

All 32 rows completed successfully with zero arena fallback, swap, and
placement-query errors. The majority resident node always matched the
requested node.

Site 74 allocated only 143 objects and occupied one 2MiB slab. The difference
between sites 68+71 and raw-046 was 0.46% in mean CXL throughput and 0.74
percentage points in paired delta, so this run found no material contribution
from site 74. Both sites 68 and 71 contributed substantial effects alone, and
their joint placement reproduced the raw-046 plateau.

## Automatic Policy Follow-up

The resulting `evidence-balanced-size-tiebreaker` policy selects the same
eight static XIndex sites and produces a byte-identical rewritten executable
as raw-046. It replaces raw-046's +6 size weight with a +1 tie breaker and uses
escape, synchronization/mutation, and worker reachability as the primary
evidence. Both executables had SHA-256
`8fc9e0f47b051a4452932819d8a80dd119a5e9a4e2179198c22c46f9319f56e4`.
A one-pair regression measured 27.385M Local versus 49.390M CXL
op/s (+80.35%), with the same 17.310GiB resident footprint and zero safety
errors. The four-pair raw-046 rows remain the stronger repeated estimate
because the rewritten executable is identical.

An exploratory policy with zero size weight also selected dynamic helper
allocations and terminated with SIGSEGV during XIndex training. It did not hit
the 64GiB memory limit. Those unsafe configs were not retained.

## Files

- `comparison.csv`: four-policy aggregate comparison
- `raw-046-pairs.csv`: per-pair throughput for the latest repeated baseline
- `policy-screen.csv`: one-pair checks for the recommended policy and the
  balanced-default control

The throughput data demonstrates a placement-associated effect, not a direct
measurement of HITM reduction. Hardware C2C/HITM counters and correctness
checks remain required for a causal claim.
