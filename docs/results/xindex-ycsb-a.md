# XIndex/YCSB-A HITM-Risk Seed Placement

The recommended `raw-046` policy placed 17.31GiB of live arena pages on CXL.
Across four one-pass pairs it improved mean throughput from 26.531M to
49.068M op/s: **+85.03% mean paired improvement**.

## One-Pass Result

Each row consumed the complete 400M-operation transaction trace once and then
exited. Local/CXL order alternated across pairs.

| Repeat | Local | CXL | CXL vs local |
|---:|---:|---:|---:|
| 1 | 26.423M op/s | 49.276M op/s | +86.49% |
| 2 | 26.094M op/s | 49.661M op/s | +90.31% |
| 3 | 27.360M op/s | 48.527M op/s | +77.36% |
| 4 | 26.248M op/s | 48.806M op/s | +85.94% |

All eight rows completed successfully with zero swap, arena fallback, and
placement-query errors. Every row reported 17.310GiB of resident arena memory
on its requested NUMA node. Mean max RSS was 30.196GiB. The retained
machine-readable summary is under
[`results/xindex/ycsb-a/one-pass-20261008/`](../../results/xindex/ycsb-a/one-pass-20261008/README.md).

## Retained Cyclic-Replay Protocol

One local or CXL row is one fresh `ycsb_bench` process:

1. Read the 100M-record YCSB-A load trace and 400M-operation transaction
   trace.
2. Construct and train XIndex. This preparation is outside the throughput
   interval but is included in wall time and peak RSS.
3. Start 31 foreground workers and one background worker.
4. For 180 seconds, each foreground worker repeatedly executes its partition
   of the transaction trace. Sample aggregate progress every 30 seconds.
5. Report `executed operations / measured seconds` as throughput, then report
   arena allocation and residency counters.

The 400M trace was therefore a reusable operation source, not a limit on the
number of timed operations. A typical row took about 4m03s--4m17s wall time:
roughly 180 seconds measured plus trace loading, index construction/training,
startup, and teardown. “Full-scale” in the retained artifacts means that the
full-size traces were loaded; it does not mean that each row consumed exactly
one transaction-trace pass.

## Comparison and Controls

The experiment compares the same seed-rewritten binary in two modes. In
`hitm-seed-local`, selected allocations use an arena bound to node 0. In
`hitm-seed-target`, that arena is bound to CXL node 2. XIndex's other memory
and all benchmark CPUs remain on node 0.

| Control | Value |
|---|---|
| Workload | YCSB A, 100M load / 400M transaction trace |
| Workers | 31 foreground + 1 background |
| CPU / ordinary memory | NUMA node 0 |
| Compared arena nodes | node 0 local / node 2 CXL |
| Timed interval | 180s, sampled every 30s |
| Repeats | 4 alternating local/CXL pairs |
| Arena | strict, 2MiB slabs, 24GiB virtual reserve, 64B alignment |
| Process limit | `MemoryMax=64G`, `MemorySwapMax=0` |
| Filesystem cache | deliberately warm; no `drop_caches` |
| Process state | fresh process for every row |

A fresh process resets XIndex, anonymous memory, heap/arena state, and runtime
counters. It does not reset the filesystem page cache or CPU caches. Placement
order alternates to reduce order bias. The retained run did not isolate OS and
interactive work onto a separate cpuset, so future publication-quality runs
should reserve one housekeeping CPU and keep all unrelated processes there.

## Retained Search Results

The curated current set keeps 12 policies that were safe, won all three
screening/confirmation pairs, and reproduce their static seed fingerprints
with the seed-only compiler. Their exact parameters and three-pair rankings
are in [`configs/hitm-seed/README.md`](../../configs/hitm-seed/README.md). All other
historical configs and raw results remain checked in alongside this shortlist.

Five candidates received a homogeneous final stage of four local/CXL pairs at
180 seconds per row:

| Config | Local (M op/s) | CXL (M op/s) | Paired delta | 95% CI | Wins | CXL resident |
|---|---:|---:|---:|---:|---:|---:|
| `raw-043` | 27.656 | 57.345 | +107.68% | +93.28--+122.09% | 4/4 | 18.88GiB |
| `raw-046` | 27.886 | 56.813 | +103.75% | +98.57--+108.92% | 4/4 | 17.31GiB |
| `raw-021` | 28.484 | 57.103 | +100.47% | +99.21--+101.73% | 4/4 | 18.88GiB |
| `raw-013` | 28.086 | 55.786 | +98.63% | +95.64--+101.62% | 4/4 | 18.88GiB |
| `raw-082` | 28.801 | 44.896 | +55.86% | +37.36--+74.37% | 4/4 | 14.16GiB |

`raw-046` is the default because it reaches the high-throughput plateau with
1.57GiB less resident arena memory than `raw-043`, while showing materially
lower paired variation. Its automatic static seeds are
`68+71+74+90+97+98+99+100`; only `68+71+74` allocate during this trace. These
IDs are reported results, not hard-coded selections.

| Site | Static function | Estimated object | Active in YCSB-A | Runtime meaning |
|---:|---|---:|---|---|
| 68 | `hash` | 96B | yes | 26.40M group-hash allocations; 3.15GiB assigned arena |
| 71 | `allocate_leaf` | 520B | yes | 26.40M leaf allocations; 14.16GiB assigned arena |
| 74 | `allocate_internal` | 520B | yes | 143 internal-node allocations; 2MiB assigned slab |
| 90 | `compact_phase_1` | 64B | no | rewritten, but this allocation path did not execute |
| 97 | `insert_ptr` | 96B | no | rewritten, but this allocation path did not execute |
| 98 | `insert_ptr` allocator | 8B | no | rewritten, but this allocation path did not execute |
| 99 | `put` | 96B | no | rewritten, but this allocation path did not execute |
| 100 | `put` allocator | 8B | no | rewritten, but this allocation path did not execute |

“Static seed” means the compiler selected and rewrote the allocation site.
“Runtime-active” means the site actually emitted one or more allocations in a
specific trace. For the target row, the three active sites collectively used
17.31GiB of resident arena memory on node 2. Arena assignment includes 64B
alignment, slot padding, and 2MiB slab granularity, so it is larger than the
sum of requested payload bytes.

## Seed-Only Cyclic-Replay Regression

After member expansion was deleted, one 180-second cyclic-replay pair
reproduced the same static and runtime fingerprints:

| Placement | Throughput | Max RSS | Arena resident | Majority node |
|---|---:|---:|---:|---:|
| local | 27.881M op/s | 30.195GiB | 17.310GiB | 0 |
| CXL | 56.969M op/s | 30.196GiB | 17.310GiB | 2 |

The paired delta was +104.33%. Both rows exited successfully with 52,791,182
arena allocations, zero fallback, zero swap, and zero placement-query errors.
All 4,537,669 resident arena pages were found on the requested node. Each of
the six 30-second intervals retained the same performance separation.

## Current One-Pass Contract

The current canonical runner no longer uses the retained duration-controlled
protocol. Every row now uses:

```text
XINDEX_ITERATION=1
XINDEX_DURATION_SECONDS=0
XINDEX_THROUGHPUT_SAMPLE_SECONDS=0
```

Each process consumes the complete 400M-operation transaction trace exactly
once and exits when the work is finished. This matches the YCSB-B execution
contract. The retained 15-, 60-, and 180-second cyclic-replay values above are
historical results and remain separate from the primary one-pass result.

## Reproduce

For a fresh checkout, restore the LFS traces and build prerequisites first:

```sh
git lfs install
./scripts/setup-benchmarks.sh
```

Validate the machine, traces, NUMA nodes, CPU count, and config without
building or running:

```sh
ARBITER_TARGET_NODE=2 ./scripts/run-xindex-hitm-seed-replay.sh --check
```

Run one complete trace pass for each side of one local/CXL pair:

```sh
ARBITER_TARGET_NODE=2 ./scripts/run-xindex-hitm-seed-replay.sh --quick
```

Run four alternating one-pass local/CXL pairs directly or under tmux:

```sh
tmux new-session -d -s arbiter-hitm-seed -c "$(pwd)" \
  'ARBITER_TARGET_NODE=2 ./scripts/run-xindex-hitm-seed-replay.sh \
   > build/arbiter-bench/xindex-hitm-seed-replay.console.log 2>&1'
```

Use `--quick` for a shorter one-pair regression check. The wrapper rebuilds by
default; set `BUILD_BENCHMARKS=0` only when the exact binary already exists.
It resolves and verifies LLVM 18 `clang++`/`opt`, including this machine's
local `.tools` fallback, refuses to overwrite an existing result, and rejects
a concurrently running `ycsb_bench` unless explicitly overridden.

Inspect `summary.md`, `runs.csv`, `throughput-samples.csv`,
`hitm-seed-sites.csv`, `interpretation.md`, and `replay-manifest.txt` in the
timestamped result directory. `interpretation.md` is generated by:

```sh
./scripts/summarize-xindex-hitm-seed-result.sh RESULT_DIR
```

With no argument, the summarizer selects the newest canonical replay. It
separates compiler-selected sites from runtime-active sites and checks the
requested/majority NUMA node, fallback count, swap count, and row status. The
retained checked-in evidence is under
[`results/xindex/ycsb-a/`](../../results/xindex/ycsb-a/README.md).

## Claim Boundary

The result demonstrates a large, repeatable throughput difference between
local and CXL placement across four complete trace passes. It does not prove
that reduced cache-line bouncing caused the gain. The runs did not collect
HITM/C2C or memory-bandwidth counters, operation-latency percentiles, or a
final correctness checksum. Those measurements and stricter CPU isolation are
required before making a causal or general performance claim.
