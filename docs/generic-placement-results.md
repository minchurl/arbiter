# Generic Placement Experiment Results

This document records high-signal experiment outcomes for the generic
shared-mutable placement path. Generated artifacts under `build/` are useful
locally, but they are not tracked by git. This file is the durable experiment
ledger.

## Configuration Names

| Config | Meaning |
|---|---|
| `native` | Uninstrumented benchmark binary. No Arbiter pass, runtime, or remote placement. |
| `all-local` | Naive all supported allocation sites rewritten through Arbiter, local memory. |
| `generic-local` | Shared-mutable heuristic sites rewritten through Arbiter, local memory. |
| `all-remote` | Naive all supported allocation sites rewritten through Arbiter, remote target node. |
| `generic-remote` | Shared-mutable heuristic sites rewritten through Arbiter, remote target node. |

All XIndex results below bind CPU and baseline memory to NUMA node 0. Remote
runs target NUMA node 1.

## 2026-07-16: Full Generic Experiment Attempt

Run shape:

```sh
REPEATS=3 ./scripts/run-generic-placement-experiment.sh
```

Artifacts, on the machine where the run was performed:

```text
build/arbiter-bench/generic-placement-experiment/
```

### Completed GUPS Runs

| Config | Repeats | Avg Time (s) | Avg GUPS | Throughput / Native |
|---|---:|---:|---:|---:|
| `native` | 3 | 97.135 | 0.329437 | 1.000x |
| `all-local` | 3 | 98.198 | 0.325873 | 0.989x |
| `all-remote` | 3 | 133.110 | 0.240403 | 0.730x |

GUPS confirmed that the mmap rewrite/placement path runs end-to-end. Remote
NUMA placement had a visible throughput penalty, but it did not trigger the
host instability seen in XIndex.

### Completed XIndex/YCSB-A Local Runs

| Config | Repeats | Time (s) | Throughput (op/s) | Throughput / Native | Status |
|---|---:|---:|---:|---:|---|
| `native` | 1 | 146.024 | 5.47856e+07 | 1.000x | ok |
| `all-local` | 1 | 147.750 | 5.41457e+07 | 0.988x | ok |
| `generic-local` | 1 | 147.429 | 5.42633e+07 | 0.990x | ok |
| `all-remote` | 1 | n/a | n/a | n/a | failed during training |
| `generic-remote` | 1 | n/a | n/a | n/a | OOM during resumed run |

The local instrumentation overhead for full XIndex/YCSB-A was small in the
first repeat. Both local instrumented variants stayed within about 1 percent of
native throughput.

### Failure Mode

The full XIndex/YCSB remote runs were unsafe as configured. Kernel logs showed
`ycsb_bench-arbi` repeatedly invoking the OOM killer with a strict NUMA memory
policy:

```text
ycsb_bench-arbi invoked oom-killer
oom-kill:constraint=CONSTRAINT_MEMORY_POLICY,nodemask=1,cpuset=/,mems_allowed=0-1,global_oom
```

This was not ordinary whole-machine memory exhaustion. It was a NUMA memory
policy failure for node 1, the Arbiter remote target node.

Observed OOM windows:

| Time | PID | Run | Observation |
|---|---:|---|---|
| Jul 16 15:48:55 | 120685 | `xindex_a_all-remote_r1` | OOM during `start training` |
| Jul 16 16:01:48 | 121489 | `xindex_a_generic-remote_r1` | Repeated OOM storm during `start training` |

The kernel killed unrelated user and system processes, including
`systemd-resolved`, `systemd-networkd`, `sshd`, `tmux`, `codex`, and editor/node
helper processes. DNS failed because `systemd-resolved` was one of the OOM
victims.

Conclusion:

- Full-trace remote XIndex/YCSB placement should not be rerun directly on the
  host.
- Remote XIndex runs must be isolated with a memory-limited cgroup or user
  systemd scope.
- A high benchmark `oom_score_adj` is useful as a second line of defense.
- The current generic heuristic does not avoid the unsafe training-phase remote
  allocation behavior on the full trace.

## 2026-07-17: Protected Scaled XIndex/YCSB-A Pilot

Run shape:

```sh
XINDEX_SCALE_LOAD_RECORDS=100000 \
XINDEX_SCALE_TX_OPS=400000 \
MEMORY_MAX=64G \
REPEATS=1 \
XINDEX_FG=8 \
XINDEX_ITERATION=3 \
./scripts/run-protected-scaled-xindex-experiment.sh
```

Artifacts:

```text
build/arbiter-bench/generic-placement-scale-100000-400000/
```

Summary:

| Config | Repeats | Avg Time (s) | Avg Throughput (op/s) | Throughput / Native |
|---|---:|---:|---:|---:|
| `native` | 1 | 0.050 | 2.40832e+07 | 1.000x |
| `all-local` | 1 | 0.066 | 1.80664e+07 | 0.750x |
| `generic-local` | 1 | 0.068 | 1.75813e+07 | 0.730x |
| `all-remote` | 1 | 0.778 | 1.54228e+06 | 0.064x |
| `generic-remote` | 1 | 0.786 | 1.52624e+06 | 0.063x |

This run completed all five XIndex configurations inside the protected scope.
It was intentionally tiny, so it should be treated as a functional and safety
check rather than a performance result.

## 2026-07-17: Protected Scaled XIndex/YCSB-A Main Run

Run shape:

```sh
XINDEX_SCALE_LOAD_RECORDS=1000000 \
XINDEX_SCALE_TX_OPS=4000000 \
MEMORY_MAX=96G \
REPEATS=3 \
XINDEX_FG=16 \
XINDEX_ITERATION=5 \
./scripts/run-protected-scaled-xindex-experiment.sh
```

Artifacts:

```text
build/arbiter-bench/generic-placement-scale-1000000-4000000/
```

All 15 runs completed successfully. No new kernel OOM events were observed
during the run. Remote XIndex runs used about 7.7 GiB maximum RSS, and the
protected systemd scope peaked at about 8.45 GiB.

Summary:

| Config | Repeats | Avg Time (s) | Avg Throughput (op/s) | Throughput / Native |
|---|---:|---:|---:|---:|
| `native` | 3 | 0.496 | 4.03143e+07 | 1.000x |
| `all-local` | 3 | 0.670 | 2.98619e+07 | 0.741x |
| `generic-local` | 3 | 0.673 | 2.97352e+07 | 0.738x |
| `all-remote` | 3 | 7.336 | 2.72623e+06 | 0.068x |
| `generic-remote` | 3 | 7.282 | 2.74652e+06 | 0.068x |

Heuristic-vs-naive comparison:

| Comparison | Throughput Ratio | Interpretation |
|---|---:|---|
| `generic-local` / `all-local` | 0.996x | No improvement; effectively tied. |
| `generic-remote` / `all-remote` | 1.007x | Tiny difference; likely not meaningful. |

Conclusion:

- The protected scaled workflow is stable and reproducible.
- The current shared-mutable heuristic does not show a meaningful performance
  win over naive all-site rewriting on scaled XIndex/YCSB-A.
- Remote placement dominates performance in this configuration: both remote
  variants drop to about 6.8 percent of native throughput.
- This result should be treated as a negative result for the current heuristic,
  not as evidence that generic shared-mutable placement improves XIndex/YCSB.

## Current Interpretation

The generic/shared-mutable path has value as an experiment harness and as a
negative baseline. It proves that Arbiter can build and run native, all-site,
and heuristic-selected benchmark variants reproducibly, and that unsafe remote
experiments can be contained with a protected systemd scope.

It does not yet prove that the shared-mutable heuristic selects a better set of
allocation sites than naive all-site rewriting.

## Next Questions

Before investing in larger performance runs:

1. Compare `ycsb_bench.sites.csv` and
   `ycsb_bench.shared-mutable-sites.csv` to verify that the heuristic is
   selecting a materially different site set from all-site rewriting.
2. Inspect whether selected XIndex allocations are training/build-time objects
   rather than transaction-phase hot mutable objects.
3. Consider excluding training allocations, or splitting the experiment so
   placement only applies to the measured transaction phase.
4. Add bounded/fallback behavior to remote allocation so node-local memory
   policy failures kill only the benchmark process, not unrelated services.
5. Test a workload where naive all-site placement is expected to over-place
   cold data, making the heuristic-vs-naive distinction more observable.
