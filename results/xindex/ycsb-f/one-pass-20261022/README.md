# XIndex/YCSB-F introduction — 2026-10-22

The final-code full run completed one native/selected-Local/selected-CXL round:

| Placement | Logical transactions/s | Measured interval |
|---|---:|---:|
| Native | 34.858M | 11.4751s |
| Selected-Local | 35.478M | 11.2747s |
| Selected-CXL | 51.686M | 7.73909s |

CXL/Local was **+45.68%** and CXL/native was **+48.27%**. This is one final-code
round, not a repeated estimate or proof of a HITM-reduction mechanism.

## Protocol

- Automatic `evidence-balanced-size-tiebreaker` policy, unchanged weights.
- Shared A input: 100M load records, 400M logical transactions, one pass.
- A's READ stays READ; each UPDATE becomes a same-worker get followed by put.
- 199,993,860 read-only and 200,006,140 RMW transactions per row.
- Actual API calls: 400,000,000 get and 200,006,140 put calls per row.
- 31 foreground + one background worker; CPU/ordinary memory on node 0.
- Same rewritten binary and strict arena on node 0 Local or node 2 CXL.
- MemoryMax=64G, MemorySwapMax=0; fresh processes, warm filesystem cache.
- No timed-duration cutoff, cyclic replay, or per-transaction Java execution.

All three rows completed 400M successful logical transactions, both RMW
sub-calls succeeded, and the sampled 4,096-key state digest matched:
`0x7474b8e9d3962859`. Local/CXL arena residency was 17.310GiB on the requested
node with zero fallback, placement-query errors, or swap. Peak RSS was
approximately 31.13GiB native and 30.20GiB selected-Local/CXL.

The static selection remained `68,71,74,90,97,98,99,100`, with runtime-active
sites `68,71,74`; no site IDs were pinned. The compiler pass and runtime were
not changed for F.

## Evidence and reproduction

- [`final/`](final/): final-code manifests, CSVs, selection, correctness output,
  source/binary hashes, raw row logs, and timing logs.
- [`development/`](development/): earlier full development check of the same
  policy/workload: 31.833M native, 34.096M Local, 49.282M CXL (+44.54% CXL/Local).
  It used an earlier parser binary and is not pooled with the final run.
- [`smoke/`](smoke/): 200K-load/1M-transaction native/Local/CXL correctness checks
  and equivalent explicit `READMODIFYWRITE` input. Smoke throughput is not a
  full-scale performance estimate.
- [`a-regression/`](a-regression/): the same final binaries also passed the
  existing A read/update correctness checks on native/Local/CXL.

```sh
./scripts/run-xindex-ycsb-f.sh --smoke
./scripts/run-xindex-ycsb-f.sh
```

See [the F protocol](../../../../docs/xindex-ycsb-f.md) for transaction units,
input semantics, settings, and limitations. F extends workload coverage on
XIndex; it does not establish generality across different data structures.
