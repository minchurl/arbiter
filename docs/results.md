# Results and design history

Measurements below come from different revisions and protocols, not one pooled
experiment. Recent runs used a Xeon Gold 6548Y+, CPUs/DRAM on node 0, CXL on
node 2, LLVM 18 and jemalloc 5.2.1. Original rows, hashes and manifests are in
the [evidence index](../results/README.md). Current run instructions are in the
[benchmark guide](benchmarks.md).

## Current runtime: strict on-demand jemalloc

The runtime merged in #22 (`783706f`) removes the large pool, direct backend
and per-pointer side table while preserving NUMA placement and C/C++ failure
contracts. Runtime C++/headers fell from **1,294 to 650 physical lines**
(**−644, −49.77%**, including comments/blanks; compiler/tests counted separately).

The final build ran exactly **one full Local/CXL pair** on November 19:
100M load records, 400M transactions, 31+1 workers, 64 GiB limit, no swap.
No fresh baseline or additional performance repeats were run.

| Implementation | Runs per placement | Local M tx/s | CXL M tx/s |
|---|---:|---:|---:|
| Bounded jemalloc, `9d90964` | 4 | 26.894 | 47.029 |
| Initial pool removal, 1,002-line runtime | 4 | 26.335 | 44.855 |
| Final strict runtime, 650 lines | 1 | 26.468 | 43.274 |

Final CXL/Local is **+63.49%**. Against the earlier bounded means, Local is
**−1.58%**, CXL **−7.98%**. This is a single observation against historical
controls, not proof of speedup, performance neutrality or a causal regression.
The initial pool-removal comparison also decreased: −2.08% Local, −4.62% CXL;
its CXL runs ranged from 40.970 to 48.088 M tx/s. The intermediate 552-line
strict-only runtime was not benchmarked; failure-contract handling brought it
to the final 650 lines.
[Final rows](../results/xindex/ycsb-a/jemalloc-strict-20261119/runs.csv)
· [Repeated comparison](../results/xindex/ycsb-a/jemalloc-demand-20261118/runs.csv)

Both final runs completed 400M transactions, made 52,791,182 selected
allocations at sites 68/71/74, and matched the 4,096-key digest
`0x7474b8e9d3962859`. All 5,000,778 located private pages were on the requested
node; six kernel zero pages were counted separately. Allocation-failure logs,
fallbacks, query errors and swap were zero. Policy and workload were unchanged;
rewritten IR matched after normalizing the new helper dispatch and debug data.

Peak RSS was 31.993 GiB versus the earlier bounded mean of 32.051 GiB
(about 58.8 MiB lower). Arena private residency stayed about 19.08 GiB.
Mapped backing grew from 20,587,741,184 to 23,578,279,936 bytes as jemalloc
chose its own growth sizes. Removing a 24 GiB virtual reservation did **not**
free 24 GiB of RSS. Initial pool-removal lifecycle timings also increased:
Local 5.510→5.680 s, CXL 5.340→5.630 s (three runs per cell). These include
page faults, NUMA queries, sorting and threads, not just allocator latency.

## Earlier allocator and XIndex results

**Custom slab → bounded jemalloc, November 17:** two full runs per allocator
and placement, with the same rewritten bitcode and eight runs total.

| Measurement | Custom slab | Bounded jemalloc | Change |
|---|---:|---:|---:|
| Local M tx/s | 27.27 | 27.36 | +0.31% |
| CXL M tx/s | 45.05 | 48.59 | +7.86% |
| Resident arena GiB | 17.31 | 19.08 | +10.21% |
| Peak process RSS GiB | 30.20 | 32.05 | +6.14% |

jemalloc rounds 520-byte objects to 640 bytes versus the slab's 576 bytes,
accounting for about 1.57 GiB of the 1.77 GiB arena increase. Correctness and
placement checks passed. In a separate five-process-per-cell allocation/release
check, median Local time rose 1.36→4.83 s and CXL 1.86→4.97 s; whole-process
timing includes touch/query/sort/thread work. Few repeats and host variation
limit conclusions. [Measurements](../results/xindex/ycsb-a/jemalloc-20261117/)

**Historical slab results:** full one-pass runs, except the explicitly archived
cyclic sweeps. A is approximately 50% reads/50% updates; F maps updates to
same-worker get/put. Throughput is millions of logical transactions/s.

| Experiment | Repeats | Native | Local | CXL | CXL/Local change |
|---|---:|---:|---:|---:|---:|
| A raw-046, October 20 ablation control | 4 pairs | — | 26.287 | 50.324 | +91.53% paired mean |
| A sites 68+71, after delete-ABI/correctness fixes | 4 pairs | — | 27.685 | 49.917 | +80.42% paired mean |
| F automatic policy, counter-free loop | 4 rounds | 33.983 | 33.953 | 50.681 | +49.27% ratio of means |

F's CXL/native gain was +49.14%. It extends workload coverage on XIndex, not
coverage of a new data structure. Earlier A ablations measured +46.35% for
site 68 alone, +50.78% for site 71, and +90.79% together. Site 71's leaf blocks
accounted for 14.16 GiB; site 74 used only one 2 MiB slab with no detectable
extra gain. This motivated reducing size from a dominant +6 score to a +1
tiebreaker while preserving the same automatic XIndex selection.
[A ablation](../results/xindex/ycsb-a/site-ablation-20261020/comparison.csv)
· [ABI confirmation](../results/xindex/ycsb-a/runtime-correctness-20261021/runs.csv)
· [F counter-free runs](../results/xindex/ycsb-f/counterfree-20261022/runs.csv)

**Read-heavy boundary:** archived YCSB-B (95% reads/5% updates) had 15
runtime-valid policies; every one-pair screen regressed with CXL, **−19.18%
to −45.34%**. None passed the promotion threshold; no repeated confirmation
followed. These are directional results, not precise per-policy effect sizes.
[Screen](../results/xindex/ycsb-b/fulltrace-sweep-20261008/screen-summary.csv)

## B-tree and coherence microbenchmark

The supplied B-tree times **600M read-only lookups** after construction.
It has no write-ratio option, and its structural insert/delete routines lack
a concurrent-write protocol. Its shared parallel RNG/accumulator also limit
repeatability. The current pass cannot rewrite its `posix_memalign` calls:
automatic selection is empty, so Local/CXL labels do not imply moved objects.
An earlier explicit node-array placement lost **50.67%** (22.24→10.97 M
lookups/s, three runs per mode); that manual path was removed. An automatic
check measured 23.02 native, 22.88 Local and 22.72 CXL with all pages local.
[Targeted runs](../results/btree-coherence/20261118/runs.csv)
· [Automatic runs](../results/allocation-policy/published-rmw-20261118/benchmark-runs.csv)

The published-RMW policy selects only the microbenchmark's shared table:

| Object | Timed access / HITM risk | Placement |
|---|---|---|
| Table (`g_table`, site 4) | CAS-protected writes; true sharing on the same entry and adjacent-entry false sharing at 32 bytes | Selected Local/CXL |
| Ballast (`g_ballast`, site 5) | Read-only after initialization; memory traffic without a continuing writer | Local |
| Victim results / thread state | Private accumulation then exit publication, or setup/teardown | Local |
| Epochs (`g_epochs`) | One writer per aligned counter; maintenance readers can share it | Static, outside allocation selection |
| Start/stop/spin flags | Mostly startup/shutdown coordination | Static, outside allocation selection |

Original weights gave table and ballast identical evidence. The new global
publication-to-pointee-RMW signal distinguishes them; runtime flags such as
100% reads cannot change a compile-time selection. Four full A pairs per policy
preserved XIndex: evidence-balanced CXL 46.34 vs published-RMW 46.30 M tx/s
(−0.08%), with byte-identical rewritten executables. Local was 27.50 vs 26.69;
all 16 rows passed validation. This is bounded-jemalloc evidence, not a new
confirmation of the final runtime.
[Decisions](../results/allocation-policy/published-rmw-20261118/decisions.csv)
· [XIndex rows](../results/allocation-policy/published-rmw-20261118/xindex-runs.csv)

The corrected adapter fixes 100%-read threshold overflow, lock acquisition
that admitted multiple writers, and non-atomic shared accesses. It validates
write totals/versions, released locks and epochs outside timing. Original
synchronization results remain historical, not correctness baselines.

Three 30-second Local/CXL pairs per variant used 32 victims, 256 entries,
50% reads, 8 GiB ballast and no noise. No counters ran during these timings.

| Corrected variant | Local Mops/s | CXL Mops/s | Local vs corrected control |
|---|---:|---:|---:|
| 32-byte entries, epoch RMW | 347.79 | 353.73 | — |
| 32-byte entries, epoch store | 375.10 | 375.46 | +7.85% |
| 64-byte entries, epoch store | 541.70 | 538.32 | **+55.76%** |

The first control Local run was slower; against its latter two runs the gain
is about 53%. The control's apparent +1.71% CXL advantage did not repeat;
padded CXL/Local was −0.63%. Padding doubles the table from 8 to 16 KiB;
RSS stays about 8.05 GiB. This is a workload optimization, **not a CXL speedup**.
[All 18 rows](../results/coherence-tuning/20261118/confirm.csv)

Separate 15-second hot-phase counters show locked loads/op fall from 1.5130
to 0.5142 with epoch stores; padding reduces Local HitM loads/op from 0.4332
to 0.3788. Address samples attributed 99.65–99.88% of mixed-workload HitM loads
to the table, and all sampled L3 misses to ballast. This supports selecting
the table, but moving its backing pages does not remove CPU cache ownership
transfers. The event counts L3 HitM loads, not all coherence traffic.
[Counters](../results/coherence-tuning/20261118/counters.csv)
· [Address samples](../results/coherence-tuning/20261118/hitm-samples.csv)
· [Intel event definition](https://perfmon-events.intel.com/platforms/emeraldrapids/core-events/core/)

Exploratory larger working sets worsened CXL performance: a 32 MB table lost
65.81% in the screen, and moving ballast lost about 87% in the earlier policy
screen. Cached metadata/power-of-two indexing regressed padded throughput
10.73% Local / 9.29% CXL and was removed. All 88 tuning rows passed workload
and placement checks; a short TSan check reported no races. Six-second screens
are exploratory and changes to mix/size are different workloads.

## Design history

| Step | What we learned / retained |
|---|---|
| Generic shared-mutable placement | Did not improve over all-site placement; direct per-object mapping inflated memory. Node-policy OOM motivated protected runs. |
| Lock-touch migration | Hooks alone cost about 8.9%; tested migration settings stayed below native. Prefer allocation-time selection. |
| Packed custom slab | Avoided per-object page waste; site-99 pilots led to automatic scoring and broad policy sweeps. |
| Seed-only policy | Removed ineffective member expansion and unused search controllers; retained configs and measured evidence. Cyclic sweeps later gave way to one-pass comparisons. |
| Correctness and A/F | Preserve matching new/delete ABI; add sampled-state and placement checks, then remove extra per-operation counters from performance loops. |
| jemalloc (#18), additional benchmarks (#21) | Delegate allocation management; add published-RMW evidence and corrected microbenchmark adapters. |
| On-demand extents (#22) | Remove fixed pool/direct fallback; keep strict NUMA, diagnostics and allocation API failure contracts. |

Throughput alone does not prove reduced HITM, and small-table contention does
not guarantee useful CXL placement. Old plans, full writeups and removed code
remain in [Git at 783706f](https://github.com/minchurl/arbiter/tree/783706f/docs);
the evidence index names earlier executable snapshots where needed.
