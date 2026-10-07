# Hot-Set Placement Experiment Results

This ledger records protected XIndex/YCSB hot-set comparisons. Generated files
under `build/` normally remain local; retain the input config, decision CSV,
effective arguments, and binary hashes with every durable result. Bounded raw
text needed to reproduce an analysis may be retained under `artifacts/`.

## 2026-08-12: 1M/4M CXL Safety and Tendency Pilot

This was a safety and tendency check, not a performance result. Codex and other
background workloads remained active, and each configuration ran once with one
YCSB iteration.

Run shape:

```sh
XINDEX_SCALE_LOAD_RECORDS=1000000 \
XINDEX_SCALE_TX_OPS=4000000 \
REPEATS=1 \
XINDEX_FG=16 \
XINDEX_ITERATION=1 \
XINDEX_DURATION_SECONDS=0 \
MEMORY_MAX=16G \
MEMORY_SWAP_MAX=0 \
ARBITER_CPU_NODE=0 \
ARBITER_MEM_NODE=0 \
ARBITER_TARGET_NODE=2 \
ARBITER_HEAP_BACKEND=direct \
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-sweep-base.config \
./scripts/run-protected-hotset-experiment.sh
```

The driver ran native, hot-set local, and hot-set target configurations. The
local and target rows used the same rewritten binary. Direct `numastat`
sampling confirmed that target pages were resident on the memory-only CXL NUMA
node 2.

### Sweep-Base Observation

`configs/hotset/xindex-sweep-base.config` selected three seeds and four
members. All four selected members already had the maximum write affinity of
5, so raising only `ARBITER_HOTSET_MEMBER_MIN_AFFINITY` would not reduce the
set.

At the 1M/4M scale:

| Metric | Value |
|---|---:|
| Hot-set local throughput | 21.28M op/s |
| Hot-set target throughput | 0.61-0.77M op/s |
| Target process maximum RSS | 5.33 GiB |
| Peak sampled CXL-node residency | 4751.89 MiB (4.64 GiB) |

The selected allocations are mostly 96-byte objects and 8-byte vector storage.
The runtime calls `numa_alloc_onnode` for each object, so every tiny allocation
can consume a page. Static selected-site count and static estimated bytes
therefore substantially understate runtime CXL footprint.

### Conservative `put` Pair

`configs/hotset/xindex-cxl-conservative.config` raises the seed threshold,
pins the score-14 `put` root (site 99 in this matching build), keeps one
fixed-size write member, rejects the dynamically sized member through a 1KiB
budget, and selects two sites total.

| Config | Throughput | Maximum RSS |
|---|---:|---:|
| Native | 40.79M op/s | 0.93 GiB |
| Hot-set local | 27.53M op/s | 0.95 GiB |
| Hot-set target | 0.443M op/s | 2.49 GiB |

A protected target recheck also completed successfully at 0.456M op/s. Peak
sampled CXL-node residency was 2025 MiB (1.98 GiB), a 57% reduction from the sweep-base
pilot. No swapping, OOM event, or kernel fault occurred.

This is a safer profile point, not a performance improvement. Targeting the
`put` allocation pair makes the workload substantially slower, and 2GiB of CXL
residency for 1M load records still demonstrates page-granularity amplification.
Do not extrapolate this config to the 100M-record full trace without either a
much lower scale limit or a pooled target allocator plus dynamic allocation and
live-byte profiling.

## 2026-08-12: Site-99 Slab/Arena Validation

This implementation validation used
`configs/hotset/xindex-cxl-arena-site99-baseline.config`, which selects only the fixed 96-byte
`put` root. Local and CXL runs used the same 2MiB-slab allocator with 64-byte
minimum alignment, making each object occupy a 128-byte slot. The only runtime
difference was binding the arena to node 0 or node 2.

The allocator smoke test placed 20,000 objects into 625 resident 4KiB pages.
All queried pages were on node 0 for the local run and node 2 for the CXL run.
Both runs reported zero fallback allocations.

At the protected 1M-load/4M-transaction scale with 16 foreground threads and a
one-second time-based measured interval:

| Metric | Value |
|---|---:|
| Site-99 allocation calls | 357,388 |
| Peak live site-99 objects | 357,388 |
| Requested payload | 34,309,248 bytes (32.72MiB) |
| Rounded slot bytes | 45,745,664 bytes (43.63MiB) |
| Assigned slab capacity | 22 slabs, 44MiB |
| Actual resident arena pages | 11,169 pages, 45,748,224 bytes (43.63MiB) |
| Local / target page majority | node 0 / node 2, with zero query errors |
| Arena fallbacks | 0 |
| Swaps / OOM / kernel faults | 0 / 0 / 0 |

The legacy direct backend would require roughly 1.36GiB for the same number of
live site-99 objects if every 96-byte allocation consumed a 4KiB page. The
arena therefore removed the dominant page-granularity amplification and the
per-object side-table insertion. Maximum process RSS was about 0.99GiB local
and target, rather than the multi-GiB direct-placement result.

Native, local-arena, and CXL-arena throughput in this one run was 63.24M,
60.23M, and 47.27M op/s respectively. The duration stopped at
1.0004-1.0012 seconds, but one second and one repeat remain validation data,
not a performance conclusion. The driver defaults to 60 seconds for the later
quiet-system tendency run.

After stopping unrelated workloads, run that 60-second comparison with the
already-built binaries as follows. Use a new `RESULT_DIR` for every run; the
driver deliberately refuses to overwrite an existing result.

```sh
RESULT_DIR="$PWD/build/arbiter-bench/hotset-arena-1m-4m-60s-run1" \
XINDEX_SCALE_LOAD_RECORDS=1000000 \
XINDEX_SCALE_TX_OPS=4000000 \
XINDEX_DURATION_SECONDS=60 \
XINDEX_FG=16 \
REPEATS=1 \
ARBITER_CPU_NODE=0 \
ARBITER_MEM_NODE=0 \
ARBITER_TARGET_NODE=2 \
ARBITER_HEAP_BACKEND=arena \
ARBITER_HOTSET_CONFIG=configs/hotset/xindex-cxl-arena-site99-baseline.config \
HOTSET_BUILD_DIR="$PWD/build/arbiter-bench/xindex-hotset-site99-baseline" \
MEMORY_MAX=16G \
MEMORY_SWAP_MAX=0 \
BUILD_BENCHMARKS=0 \
MKL_RUNTIME_DIR=/opt/intel/oneapi/mkl/2025.2/lib \
./scripts/run-protected-hotset-experiment.sh
```

This executes three measured rows—native, arena on node 0, and the same arena
on CXL node 2—so the measured portion is about three minutes plus data loading
and index construction.

## 2026-08-12: 20M/80M 32-Core Overnight Result

This run used 31 foreground workers and one XIndex maintenance worker on the
32 physical cores of NUMA node 0. Local and CXL order alternated by repeat.
Each row measured 900 seconds, giving eight paired comparisons and four hours
of measured time (4:03:31 wall time including setup).

| Metric | Local arena | CXL arena |
|---|---:|---:|
| Mean throughput | 13.0925M op/s | 13.1269M op/s |
| Throughput coefficient of variation | 1.82% | 2.40% |
| Mean maximum RSS | 11.875GiB | 11.941GiB |
| Mean resident selected-site arena | 563.8MiB | 566.9MiB |

The paired mean difference was CXL +0.263%, but CXL won only three of eight
pairs and the median paired difference was CXL -0.449%. The paired 95%
confidence interval was approximately -1.71% to +2.23%, and an exact
sign-flip test gave p=0.781. The earlier two-minute result of CXL +17.4% did
not reproduce with longer paired measurements. Site 99 placement is therefore
performance-neutral at the resolution of this experiment; it is not evidence
of a CXL speedup or slowdown.

All 16 rows completed with zero swap, major fault, arena fallback, placement
query error, or nonzero exit status. Every queried target arena page was on
node 2. Maximum process RSS remained about 12.1GiB under a 64GiB hard limit,
so the memory limit did not constrain the result. Mean CPU utilization was
about 3157% in both modes, confirming the intended 32-core saturation, but CPU
utilization does not measure cache stalls or HITM. No HITM counter was recorded
in this run.

### Placement-policy takeaway

Moving more than site 99 to CXL remains a valid next experiment, but simply
lowering the compile-time threshold is not a controlled policy. It can admit
dynamic-size sites, latency-sensitive tree storage, and small bookkeeping
allocations together. The current fixed-shape arena can safely test a staged
set of build-specific fixed-size candidates from the retained site report:

1. site 99: `put`, 96 bytes, score 14 (current reference);
2. add site 97: `insert_ptr`, 96 bytes, score 14;
3. add site 68: `hash`, 96 bytes, score 12;
4. optionally add site 90: `compact_phase_1`, 64 bytes, score 12;
5. test 8-byte bookkeeping sites 69, 98, and 100 separately rather than
   combining them with the payload candidates.

Sites 71/74 (fixed 520-byte tree allocations) and all dynamic-size candidates
should be later, separately bounded experiments. Explicit site IDs are valid
only for the matching build. A better long-term design is to rewrite a broad
safe fixed-size candidate set once, then choose `local`, `CXL`, or a placement
ratio per site at runtime. That permits site and ratio sweeps with one binary
without conflating selection changes with rebuild changes.

### Run-state and cache takeaway

The current protected driver starts a fresh process for every row. This resets
the XIndex instance, heap, anonymous mappings, arena metadata, and arena pages.
It does **not** globally clear Linux file page cache or CPU caches. The trace is
fully parsed into application memory and the index is rebuilt before the
measurement timer starts, so trace-file I/O is outside the measured interval.
Index construction also touches the new data structure, but there is no
explicit workload warm-up phase.

For future steady-state coherence experiments, prefer a fixed unmeasured
workload warm-up (for example 60 seconds) before starting each measured timer,
while retaining fresh processes, alternating order, and a short cooldown.
Do not automatically use `drop_caches`: it is a privileged, system-wide action,
does not clear anonymous memory or CPU caches, and can add unrelated cold-I/O
noise. Use it only for a separately labeled cold-start experiment. Future
drivers should record the warm-up duration and pre-run memory/NUMA state in the
result manifest.

## 2026-08-14: Automatic Fixed-Size Hot-Set Screening

This tuning pass removed the build-specific site-99 ID from the default
policy. Site 99 remains only in
`configs/hotset/xindex-cxl-arena-site99-baseline.config` as a reproduction
reference. Automatic policies selected fixed-size roots by score and rank;
dynamic-size sites and caller/callee expansion remained disabled.

The benchmark now supports epoch-based interval sampling through
`XINDEX_THROUGHPUT_SAMPLE_SECONDS`. Workers still increment only their private
operation counters and inspect the existing control word every 256 operations.
On a sample request, each worker publishes one snapshot. A 15-second smoke run
with sampling disabled and a 10-second sample run completed at 57.35M and
57.98M op/s respectively. The 1.1% difference is within single-short-run
noise, and the interval operation totals exactly matched the final total.

All screening rows used YCSB A, 20M load records, 80M transactions, 31
foreground workers plus one background worker on node 0, a 60-second measured
interval, and 10-second samples. Local arenas were bound to node 0 and CXL
arenas to node 2. The table uses the final 30 seconds instead of the aggregate
because several rows had a large startup-throughput phase.

| Policy | Resolved selected sites | Local | CXL | CXL/local | CXL arena residency |
|---|---|---:|---:|---:|---:|
| site-99 reference | 99 (`put`) | 12.893M | 13.046M | +1.19% | 567.5MiB |
| automatic k1 | 97 (`insert_ptr`) | 12.978M | 14.988M | +15.49% | 1020.0MiB |
| automatic k2 | 97, 99 | 13.074M | 14.990M | +14.66% | 1587.6MiB |
| automatic k3 | 68, 97, 99 | 12.403M | 14.401M | +16.10% | 2224.5MiB |
| automatic k4 | 68, 90, 97, 99 | 12.666M | 14.345M | +13.26% | 2224.6MiB |

The one native anchor ended at 12.712M op/s over its last 30 seconds. It is a
drift indicator, not a paired denominator. Aggregate 60-second deltas are also
not used for promotion because candidate order and the startup phase affected
them strongly. Since k4 did not improve on k3 and had already crossed the
2GiB arena warning threshold, the more aggressive k6 policy was not run.

Automatic k1 and k3 were then confirmed for 180 seconds per local/CXL row.
The steady metric below combines the final 12 ten-second intervals (roughly
the last 120 seconds).

| Policy | Local steady | CXL steady | CXL/local | CXL arena residency |
|---|---:|---:|---:|---:|
| automatic k1 | 12.104M op/s | 14.567M op/s | +20.35% | 1020.0MiB |
| automatic k3 | 12.960M op/s | 13.788M op/s | +6.39% | 2224.5MiB |

Every screening and confirmation row completed with zero swap, arena
fallback, and placement-query errors. Maximum RSS was about 12-13GiB under a
40GiB hard limit, and queried arena pages had the intended node majority.
Automatic k1 is therefore the overnight finalist: it had the larger sustained
placement effect while using less than half of k3's CXL-resident arena.

These are adaptive tuning observations, not independent evidence for a final
performance claim. The unattended confirmation driver is
`scripts/run-hotset-auto-overnight.sh`. The final design deliberately excludes
site 99: it is a manually pinned, build-specific reference with an existing
eight-pair 15-minute result, not an output of the automatic policy being
confirmed.

The driver instead runs seven rounds of native, automatic-k1 local, and
automatic-k1 CXL at 15 minutes per row. The first six rounds cover every order
permutation once, balancing each mode's row position; round 7 is a post-soak
sentinel. After round 6 it adds one independent 60-minute automatic-k1 CXL
soak. This preserves the original 6.25 measured-hour budget while increasing
the main paired sample from five to seven and adding a direct long-duration
stability check.

All 22 rows use fresh processes, 60-second throughput samples, a five-second
cooldown, 31 foreground plus one background worker on node 0, `MemoryMax=40G`,
zero swap, a strict 4GiB arena cap, and fail-fast result validation. The
primary result is the seven round-level CXL/local steady-state deltas after
discarding the first 60 seconds. The 60-minute CXL row is analyzed separately
for throughput drift and final memory growth; it is not pooled as an eighth
paired observation. The driver does not invoke `drop_caches`.

The completed run's manifest, aggregate CSVs, 22 row logs and resource logs,
compiler reports, and 375 throughput samples are preserved in the
[Git-tracked raw artifact archive](artifacts/hotset-auto-overnight-20260814-012754/README.md).
