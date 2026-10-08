# Validated Results

Arbiter's current evaluation uses heuristic-guided HITM-risk seed placement:
compile-time seed selection followed by allocation-time placement in a
NUMA-bound slab arena. It does not expand seeds to related members and does
not migrate already allocated objects.

## Primary Result: XIndex/YCSB-A One Pass

The automatic `raw-046` policy selected a runtime allocation fingerprint of
sites `68+71+74`. Across four complete-trace local/CXL pairs:

| Placement | Mean throughput |
|---|---:|
| Local arena | 26.531 M op/s |
| CXL arena | 49.068 M op/s |

The mean paired improvement was **+85.03%**, and CXL won all four pairs. Every
row consumed the 400M-operation trace once and exited. See
[the full YCSB-A result](xindex-ycsb-a.md). Earlier 180-second cyclic-replay
results are retained there as historical evidence.

## Workload Boundary: XIndex/YCSB-B

YCSB-B contains approximately 95% reads and 5% updates. A full-trace screen of
the same 100-config parameter space produced 15 runtime-valid local/CXL pairs;
all 15 regressed with CXL, from -19.18% to -45.34%. This suggests that the
coherence benefit did not offset CXL access cost for this read-heavy workload.
See [the YCSB-B result](xindex-ycsb-b.md).

The YCSB-B values are directional screening evidence, not confirmed
per-policy effect sizes. The one-pass `raw-046` YCSB-A result provides a
protocol-matched positive write-heavy reference, while all runtime-valid
YCSB-B candidates were negative. No YCSB-B policy passed the promotion
threshold, so its planned multi-pair confirmation stage did not run.

## Comparison Contract

`native` uses the unmodified binary. `hitm-seed-local` and
`hitm-seed-target` use the same rewritten binary and strict arena; only the
arena NUMA node changes. Therefore:

```text
rewrite/allocator overhead = seed-local / native
CXL placement effect       = seed-target / seed-local
end-to-end effect           = seed-target / native
```

All reportable rows used fresh processes, 31 foreground workers plus one
background worker, CPU and ordinary memory on node 0, CXL memory on node 2,
`MemoryMax=64G`, no swap, and strict zero-fallback arena placement. The
filesystem page cache remained warm; the drivers did not invoke system-wide
`drop_caches`.

## Evidence

Machine-readable retained results live under [`results/xindex/`](../../results/xindex/README.md).
Historical plans, superseded implementations, and failed controller runs are
described separately under [`docs/history/`](../history/README.md).

The measured throughput differences do not by themselves prove reduced HITM.
A causal claim still requires correctness validation, HITM/C2C counters,
memory-bandwidth counters, and latency measurements.
