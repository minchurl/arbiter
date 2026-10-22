# XIndex Runtime and Correctness Validation

Date: 2026-10-21

Branch: `validation/xindex-runtime-correctness`
Policy under confirmation: automatic Site 68+71 policy

## Current measurement loop

The per-operation attempted/successful counters have been removed from the
benchmark. The measured loop again uses only the original throughput counter.
After timing, the driver reports that existing total as
`xindex-operation-count executed=...` and optionally validates the 4,096-key
state digest. Validation scripts check the executed count, sampled state, and
placement. They no longer claim to check every operation's return value.

The measurements below are retained historical evidence from the
counter-instrumented driver. They are not counter-free remeasurements.

The removal was build-checked and smoke-tested with a 200K-record load and
1M-operation trace on native, arena node 0, and arena node 2. All three rows
reported 1M executed operations and the same 4,096-key digest
`0x9d30d99a719185fa`; arena rows had zero fallback and placement-query errors.
The automatic policy still selected the same eight static sites. The subsequent
[counter-free F remeasurement](../xindex-ycsb-f.md) passed all 12 full-trace rows.
The [2026-10-22 counter-free A/F demo](../../results/xindex/af-demo-20261022-1447/README.md)
then measured one Local/CXL pair per workload with the automatic evidence-balanced
policy: A 26.593M/49.304M transactions/s (+85.41%), F 32.959M/50.437M (+53.03%).
All four rows passed executed-count, sampled-state, and placement checks.
The placement benefit remains after the ABI fixes; the older change from
+90.79% to +80.42% was not an isolated measurement of correctness-fix overhead.
The historical four-pair Site 68+71 measurements below remain separate evidence.

## Result

The runtime/correctness gates passed. Native, rewritten-Local, and
rewritten-CXL produced the same operation outcomes and sampled final-state
digest in the short validation. All eight rows of the four-pair full-trace
confirmation completed 400M operations without a failed operation or sampled
digest mismatch.

The full one-pass Site 68+71 result remained positive after the ABI fixes and
correctness instrumentation:

| Pair | Local | CXL | Paired delta |
|---:|---:|---:|---:|
| 1 | 28.223M op/s | 49.994M op/s | +77.14% |
| 2 | 26.673M op/s | 50.769M op/s | +90.34% |
| 3 | 28.023M op/s | 49.555M op/s | +76.84% |
| 4 | 27.822M op/s | 49.350M op/s | +77.38% |
| Mean | **27.685M op/s** | **49.917M op/s** | **+80.42%** |

The paired-delta standard deviation was 5.73 percentage points. CXL won all
four pairs. This supports the existence of a placement effect; it does not by
itself prove that reduced HITM is the mechanism.

## Fixes made before measurement

The validation found and fixed two runtime ABI problems:

1. The LLVM rewrite had collapsed ordinary, array, sized, aligned, and
   sized-aligned C++ delete calls into one-argument helpers. The rewrite now
   preserves the original delete variant for untracked fallback pointers.
2. The direct backend accepted an alignment argument but ignored it. It now
   validates the alignment and uses an aligned allocation when necessary.

The runtime smoke covers tracked and untracked ordinary/array/sized/aligned
delete helpers and checks returned alignment. Its ASan+UBSan execution passed.
The LLVM smoke also verifies every rewritten delete helper name in IR.

The strict arena boundary test passed on both Local node 0 and CXL node 2. It
confirmed fixed-size reuse and placement while rejecting same-site size
changes, alignment changes, and objects larger than half a slab.

## Correctness evidence

The historical validation driver reported attempted and successful counts by
operation type. It also read a deterministic 4,096-key sample after the timed
region and printed an FNV-1a state digest.

The short 200K-load/1M-operation validation covered native, Site 68+71 Local,
Site 68+71 CXL, raw-046 Local, and raw-046 CXL. Every row completed all 500K
reads and 500K updates successfully. Their state digest was identical:

```text
0x9d30d99a719185fa
```

Each full-trace row reported:

```text
attempted=400000000 successful=400000000 failed=0
read_attempted=199993860 read_successful=199993860
update_attempted=200006140 update_successful=200006140
sampled_keys=4096 successful_reads=4096 failed_reads=0
digest=0x7474b8e9d3962859
```

The full confirmation used 100M load records, one pass over the 400M YCSB-A
transaction trace, 31 foreground threads, one background thread, CPU and
ordinary memory on node 0, and the arena on node 0 or node 2. No timed-duration
cutoff or cyclic replay was used.

## Placement and safety evidence

Every full row had the same runtime allocation fingerprint:

| Site | Object size | Allocations |
|---:|---:|---:|
| 68 | 96 B | 26,395,417 |
| 71 | 520 B | 26,395,622 |

The arena assigned 17.312GiB and had 17.310GiB resident. Local rows reported
node 0 as the majority resident node; CXL rows reported node 2. All eight rows
had zero arena fallback, zero placement-query errors, zero swap, exit status
zero, and approximately 30.196GiB maximum RSS under `MemoryMax=64G` and
`MemorySwapMax=0`.

The validated rewritten binary SHA-256 was:

```text
89d29c18299e8172aa885e148e1672c18185a418d23899022af01107033e20d7
```

The retained local result directories are:

```text
build/arbiter-bench/xindex-runtime-correctness-20261021-194900/
build/arbiter-bench/xindex-runtime-correctness-raw046-20261021-2025/
build/arbiter-bench/xindex-runtime-correctness-full-20261021-2000/
build/arbiter-bench/xindex-runtime-correctness-full-4pair-20261021-2010/
```

The compact manifest, CSVs, selection artifacts, raw row logs, and time logs
are retained in
[`results/xindex/ycsb-a/runtime-correctness-20261021/`](../../results/xindex/ycsb-a/runtime-correctness-20261021/README.md).

## Reproduction

Run the fail-closed short gates first:

```bash
./scripts/validate-xindex-runtime-correctness.sh
```

Then run a full diagnostic pair or the four-pair confirmation:

```bash
./scripts/validate-xindex-runtime-correctness-full.sh
./scripts/validate-xindex-runtime-correctness-full.sh --four-pairs
```

The current drivers stop on an incomplete executed-operation count, sampled
read failures, state-digest disagreement, arena fallback, placement failure,
process failure, or an incomplete result matrix.

## Decision

The earlier Site 68+71 effect was not caused by the identified delete ABI or
operation-counting gaps. XIndex work may continue from the validated runtime.
The next causal gate is hardware evidence: collect HITM/C2C, memory bandwidth,
and latency counters for matching Local/CXL runs before describing the
throughput difference as HITM reduction.
