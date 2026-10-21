# XIndex Runtime-Correctness Confirmation (2026-10-21)

This directory retains the four-pair, full one-pass Site 68+71 confirmation
after fixing allocation/delete ABI handling and adding operation-success and
state-digest validation.

## Outcome

| Placement | Mean throughput |
|---|---:|
| Local arena, node 0 | 27.685M op/s |
| CXL arena, node 2 | 49.917M op/s |

The mean paired improvement was **+80.42%**. CXL won all four pairs.

Every one of the eight rows:

- completed exactly 400,000,000 successful operations with zero failures;
- produced state digest `0x7474b8e9d3962859` over the same 4,096 keys;
- reported 52,791,039 Site 68+71 arena allocations;
- placed 17.310GiB of resident arena memory on the requested node;
- had zero fallback, zero placement-query errors, zero swap, and exit code 0.

See [`runs.csv`](runs.csv) for per-row performance/safety fields,
[`replay-manifest.txt`](replay-manifest.txt) for topology and execution
conditions, and [`logs/`](logs/) for the retained correctness, allocation, and
residency output. The complete load and transaction traces and built binaries
are intentionally not duplicated here; [`binaries.sha256`](binaries.sha256)
records the exact binary hashes.

The interpretation and reproduction commands are documented in
[`docs/results/xindex-runtime-correctness.md`](../../../../docs/results/xindex-runtime-correctness.md).
