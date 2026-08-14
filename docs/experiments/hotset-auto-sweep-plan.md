# XIndex Automatic Hot-Set Sweep Plan

Status: screening, 180-second confirmation, and overnight confirmation were
executed on 2026-08-14. The overnight interpretation remains to be added to
the durable results ledger.

This document freezes the methodology for the next XIndex/YCSB experiment so
that short-term tuning and overnight confirmation use the same terminology,
controls, and promotion rules. The experiment removes the site-99 pin from the
default policy, retains site 99 only as an explicit reference configuration,
and compares automatically selected fixed-size hot sets against that reference.

## Comparison Modes and Terminology

Use **native baseline**, not `naked`, for the build that does not run the
Arbiter LLVM rewrite or use the Arbiter placement runtime.

| Mode | Binary and placement | What it measures |
|---|---|---|
| `native` | Ordinary optimized XIndex binary, without the Arbiter rewrite | Uninstrumented end-to-end baseline |
| `arbiter-local` | Rewritten binary and arena runtime, selected allocations on NUMA node 0 | Compiler/rewrite/runtime/arena overhead without CXL placement |
| `arbiter-cxl` | The same rewritten binary and arena runtime, selected allocations on CXL NUMA node 2 | Combined Arbiter overhead and CXL placement |

Report all three comparisons separately:

```text
Arbiter machinery overhead = arbiter-local / native
CXL placement effect       = arbiter-cxl / arbiter-local
End-to-end effect          = arbiter-cxl / native
```

The primary placement comparison is `arbiter-cxl / arbiter-local`, because
these two rows use the same rewritten binary and differ only in the NUMA node
to which the selected arenas are bound. Never attribute `arbiter-cxl / native`
entirely to CXL placement.

The native binary does not depend on a hot-set selection config. A short sweep
therefore uses native anchor runs at the beginning and end rather than
rebuilding or rerunning an identical native binary for every candidate. The
overnight experiment runs one native anchor in every round.

## Low-Interference Throughput Sampling

Throughput sampling must not introduce an atomic increment into every YCSB
operation. Keep the existing worker-owned operation counter for the final
aggregate. The main thread requests a snapshot by changing a sample epoch in
the control word that workers already inspect every 256 operations. A worker
copies its counter to an atomic snapshot only when that epoch changes.

This adds, per sample, one control-word update, one snapshot store per
foreground worker, and one short main-thread wakeup. It does not add a new
atomic operation to the per-operation path.

Sampling intervals:

- 10 seconds for 60-180 second screening runs;
- 60 seconds for 15-minute confirmation runs;
- `0` disables interval sampling for the sampling-overhead control;
- do not use a 10-minute interval for a 15-minute run, because one sample
  cannot identify an early-to-late throughput change.

Each sample should record actual elapsed time, interval operations, interval
`op/s`, cumulative operations, and cumulative `op/s`. The protected driver
should retain the raw benchmark log and consolidate samples into a CSV with
the config, mode, repeat, and elapsed time. Final aggregate throughput remains
the source of truth for the complete row.

Before the sweep, compare sampling disabled with 10-second sampling in a short
local smoke test. Treat the sampler as validated only if completion, operation
accounting, and duration are correct and no throughput difference beyond
ordinary short-run noise is visible.

## Placement Policies

The default automatic policy must have an empty
`ARBITER_HITM_SEED_SITE_IDS`. Preserve the old site-99-only policy in a clearly
named baseline config. All automatic candidates in this sweep use fixed-size
sites only, `ARBITER_HITM_INCLUDE_DYNAMIC_SIZE=0`, no hot-set expansion, and
the strict slab/arena backend.

The following resolved site IDs are expectations from the retained build
report, not portable policy inputs. Every rebuilt binary must record and check
its own `hotset-sites.csv` before execution.

| Candidate | Selection policy | Expected sites in the retained build | Purpose |
|---|---|---|---|
| `baseline-99` | Explicit site 99 | 99 | Reproduce the previous reference |
| `auto-k1-s13` | Score >= 13, top 1 | 97 | Isolate the automatic top-ranked seed |
| `auto-k2-s13` | Score >= 13, top 2 | 97, 99 | Select both score-14 payload sites |
| `auto-k3-s12` | Score >= 12, top 3 | 97, 99, 68 | Add the next 96-byte site |
| `auto-k4-s12` | Score >= 12, top 4 | 97, 99, 68, 90 | Add the 64-byte compaction site |
| `auto-k6-s12` | Score >= 12, top 6 | 97, 99, 68, 90, 98, 100 | Optional aggressive tail including the paired 8-byte sites |

Do not test `auto-k6-s12` if `auto-k4-s12` already exceeds the memory safety
budget or has a clear steady-state regression. Dynamic-size sites, fixed
520-byte tree allocations, and probabilistic placement are separate future
dimensions; they are deliberately excluded from this sweep.

## Short-Term Successive-Halving Sweep

Fixed run shape:

```text
workload:                 YCSB A
load / transactions:     20M / 80M
foreground / background: 31 / 1
CPU / local / CXL node:   0 / 0 / 2
measured duration:        60 seconds for screening
sampling interval:       10 seconds
MemoryMax / swap:         40G / 0
backend:                  strict arena, no fallback
```

### Stage 0: instrumentation smoke

Build the sampling change and compare sampling disabled with 10-second
sampling. Check exact termination, aggregate accounting, parseability, arena
reporting, and NUMA placement. This is validation, not a performance result.

### Stage 1: 60-second screening

Run a native anchor, then one local/CXL pair for each safe candidate. Alternate
local-first and CXL-first order across candidates. Run another native anchor
at the end to expose gross machine drift.

Analyze each completed candidate immediately. Record:

- aggregate `arbiter-cxl / arbiter-local` and both modes versus native;
- median interval throughput after the first 10 seconds;
- first-20-second versus last-20-second throughput change;
- interval coefficient of variation;
- arena allocation, peak-live, assigned, and resident bytes;
- maximum RSS, swap, fallback, placement-query errors, and majority NUMA node.

Stop a candidate and its more aggressive supersets when it has an execution or
placement failure, a fallback, swap, unsafe memory growth, a clear sustained
local-relative regression, or a disproportionately large CXL footprint with
no throughput benefit. Use 2 GiB of selected-arena residency as the initial
promotion warning threshold; do not promote above it without an explicit
benefit and a separate capacity review.

### Stage 2: 180-second confirmation

Promote at most the two best safe automatic policies. Re-run the following for
180 seconds per row with 10-second sampling:

1. site-99 reference;
2. automatic candidate 1;
3. automatic candidate 2, if it remains competitive.

Promotion is based primarily on steady-state `arbiter-cxl / arbiter-local`,
then on stability and CXL bytes. A favorable first interval or a favorable
`arbiter-cxl / native` ratio alone is insufficient. Short-sweep results are
tuning data and must not be reported as independent confirmation evidence.

## Overnight Confirmation

Prebuild and hash the selected binary before execution. The unattended driver
must have a check-only mode, use fresh result directories, retain the config
and manifest, require strict zero-fallback placement, and fail fast on an
invalid result. Use a fresh process for every row and a short cooldown; do not
invoke system-wide `drop_caches` automatically.

The final overnight design spends its budget only on the automatically
selected finalist:

| Phase | Rows | Duration | Measured time |
|---|---:|---:|---:|
| Main confirmation | 7 rounds x (native, auto-k1 local, auto-k1 CXL) | 15 minutes per row | 5.25 hours |
| CXL soak | 1 auto-k1 CXL row after round 6 | 60 minutes | 1 hour |
| Total | 22 rows | | 6.25 hours |

Site 99 is not rerun in this phase. It was a manually pinned, build-specific
reference rather than an output of the automatic selection policy, and an
eight-pair 15-minute result is already retained. Its config and historical
result remain available for reproduction, but spending ten more rows on it
would not directly confirm the automatic policy.

The first six main rounds use each permutation of native, local, and CXL once:
`N-L-C`, `L-C-N`, `C-N-L`, `N-C-L`, `C-L-N`, and `L-N-C`. This places each
mode twice in every row position and balances pairwise order. The one-hour CXL
soak follows round 6, and round 7 (`N-L-C`) is a post-soak sentinel.

The primary performance unit is one round-level auto-k1 CXL/local pair
(`n=7`), using the 60-900-second portion of each 15-minute row as steady state.
Report paired mean and median deltas, dispersion, target win count, confidence
intervals, and native-relative machinery/end-to-end ratios. Native-relative
ratios remain secondary to the same-binary CXL/local comparison.

Analyze the one-hour CXL soak separately rather than pooling it into the seven
paired observations. Report minute-level throughput, first/middle/last-window
drift, final arena allocations and residency versus shorter rows, maximum RSS,
swap, fallbacks, and placement errors. The soak tests temporal stability and
capacity; it is not an additional independent local/CXL pair. Selection claims
must come from the overnight confirmation, not from whichever short candidate
happened to have the largest point estimate.

## Screening Outcome

The 2026-08-14 screening selected `auto-k1-s13` as the single overnight
finalist. The automatic top-1 policy resolved to the fixed 96-byte
`insert_ptr` allocation in this build without encoding its site ID. Over the
last 120 seconds of the 180-second confirmation, CXL placement was 20.35%
above the matching local-arena row with about 1020MiB resident in the selected
arena. Automatic k3 produced only a 6.39% steady placement delta while using
about 2224.5MiB, so it was not promoted.

The execution stopped at k4 during screening because k4 did not improve on k3
and both crossed the 2GiB promotion warning threshold; k6 was therefore not
run. The site-99 180-second repetition was omitted because the retained
eight-pair, 15-minute result already established it as the long-run reference.
Only one native screening anchor was run, so native-relative short-run ratios
are not used as paired evidence. Full measurements and safety observations are
recorded in [the hot-set results ledger](hotset-results.md).
