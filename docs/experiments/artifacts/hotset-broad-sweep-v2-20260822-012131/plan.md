# XIndex Full-Trace Broad Hot-Set Sweep

Status: ready for an unattended run. The driver has a check-only mode; creating
this plan did not start a benchmark.

## Question and Scope

The experiment searches for automatic, pin-free allocation-site policies that
improve XIndex/YCSB A throughput when selected objects are allocated on CXL
NUMA node 2. It compares the same rewritten binary with its arena on local
node 0 and on CXL node 2. `site 99` is not hard-coded.

This is a compile-time parameter sweep, not a true continuous CXL-ratio sweep.
The current runtime moves an entire selected allocation site. Different site
sets therefore produce discrete migration volumes. Probabilistic placement or
one-local/one-CXL interleaving requires a separate runtime implementation.

## Fixed Safety Envelope

Every measured row is a fresh benchmark process in a user systemd scope with:

| Item | Value |
|---|---:|
| Trace | 100M load / 400M transactions, YCSB A |
| Foreground/background workers | 31 / 1 |
| CPU/local/CXL NUMA nodes | 0 / 0 / 2 |
| `MemoryMax` / `MemorySwapMax` | 64G / 0 |
| Arena backend | strict; no direct-allocation fallback |
| Arena virtual reserve | 24 GiB (`MAP_NORESERVE`) |
| Controller wall-time limit | 8 hours |

The 64G limit was selected after a cold-cache full-trace local row completed at
about 31.9 GiB peak RSS with no cgroup `max`, OOM, swap, or arena-fallback
event. A matching CXL row placed its resident arena bytes on node 2. The 24 GiB
arena is virtual capacity, not 24 GiB of immediately committed memory; the row
still cannot exceed the 64G cgroup cap.

The script never drops page cache, restores traces, or changes other programs'
CPU affinity. Each process resets XIndex and allocator state, while the trace
page cache is intentionally left warm and shared across policies. Close VS
Code, Codex, and other active work before the unattended run. Host-wide task
migration is outside this driver because it would mutate unrelated processes.

## Candidate Space

The v2 controller deterministically generates 100 configurations. The first 14
are designed anchors, including automatic k1, k2, k3, and k6 references, two
policies reconstructed from the useful part of the first sweep, and several
aggressive expansion policies. The remaining configurations vary:

- minimum HITM score and seed count;
- escape, synchronization, worker-reachability, and size weights;
- escape/synchronization requirements;
- large-allocation threshold (only compile-time constant sizes are admitted);
- expansion on/off, total-site and per-seed member caps;
- member affinity and call/load traversal depth;
- estimated-byte budget.

`ARBITER_HITM_SEED_SITE_IDS` is empty in every generated config. After each
build, identical selected-site ID sets are collapsed. At most 50 statically
unique binaries enter the screen; build failures and empty selections are
recorded and do not abort the search.

All v2 configurations use `ARBITER_HITM_INCLUDE_DYNAMIC_SIZE=0`. The first
sweep showed a deterministic failure mode when a selected site passed different
sizes to the current fixed-slot arena: strict allocation returned null after a
slot-size mismatch and XIndex later segfaulted. The controller independently
checks the compiler report and refuses to run any build that still selects a
nonconstant size. This is an arena-compatibility filter, not a performance
preference.

## Adaptive Schedule

One independent observation is one fresh process. Throughput samples inside a
process describe drift; they are not counted as independent repetitions.

| Phase | Candidates | Additional local/CXL pairs | Measured time per row | Sample interval |
|---|---:|---:|---:|---:|
| Screen | up to 50 | 1 | 15 s | 5 s |
| Confirmation | up to 16 | 2 (3 total) | 60 s | 10 s |
| Final | up to 5 | 4 (7 total) | 180 s | 30 s |

Local-first and CXL-first order alternates between pairs. A native binary runs
only at the start, middle, and end as a machine-drift anchor; it is not rerun
for every parameter configuration.

Screen promotion requires both rows to be `ok`, zero swap/fallback/placement
query errors, local majority residency on node 0, CXL majority residency on
node 2, and the same nonempty runtime allocation-site fingerprint. It drops
only candidates below -15% CXL-over-local throughput, then keeps up to two per
runtime fingerprint and up to 16 overall. Keeping two avoids letting a single
noisy 15-second pair choose between configurations that execute the same site
set.

After three total pairs, confirmation drops only candidates whose mean paired
delta is below -10%, then keeps one representative per runtime fingerprint and
up to five overall. Final ranking uses seven total paired fresh processes and
also reports sample standard deviation and CXL win count. Thus the rerun stays
broad through confirmation rather than replaying only the four earlier
winners. Short screening can reject clearly poor settings, but only the longer
phases should support a performance claim.

## Timing and Failure Handling

At the maximum candidate counts, the estimate is approximately 7.5 hours (207
fresh processes), using the observed 65-second full-trace setup cost per fresh
process. The controller has both an eight-hour stop time and an optional
absolute deadline.
Before every pair it reserves setup, measurement, cooldown, and finalization
time. It stops cleanly rather than starting a pair that is unlikely to finish.
Each individual row also has a timeout.

OOM, timeout, missing arena activity, and compiler failures are recorded per
candidate. They disqualify that candidate but do not discard the rest of the
sweep. `arena-report-missing` is interpreted as a no-activity result, not as a
reason to terminate the controller.

Controller parsing is treated differently from a benchmark failure. Check mode
executes the exact `awk` row-count expression used after every row. Runtime
parse failures are counted, written to the manifest, stop promotion, and make
the final status `controller-parse-error`; they can no longer silently produce
an empty ranking and a false `complete` status.

## Outputs

The result directory contains:

- every resolved config, rewritten build, compiler decision CSV, and build log;
- `candidates.csv` and `selected-candidates.csv` for static de-duplication;
- `observations.csv` with throughput, RSS, swap, arena volume, residency, and
  actual runtime-site fingerprint for every fresh process;
- `throughput-samples.csv` with all within-process throughput samples;
- phase summaries, rankings, and promotion lists;
- three native anchors, manifest, hashes, initial Git status, and full console
  log.

The result directory is under `build/arbiter-bench` and is normally ignored by
Git. After analysis, copy the compact CSVs and conclusions into
`docs/experiments`; do not commit all rewritten binaries.

## Commands

Check only:

```sh
cd /home/shin/arbiter
./scripts/run-hotset-broad-sweep-overnight.sh --check
```

Run in the foreground:

```sh
cd /home/shin/arbiter
OVERNIGHT_END_DEADLINE='2026-08-21 09:00' \
  ./scripts/run-hotset-broad-sweep-overnight.sh --run
```

Run unattended after check mode succeeds:

```sh
tmux new-session -d -s hotset-broad-v2 \
  "cd /home/shin/arbiter && exec env OVERNIGHT_END_DEADLINE='2026-08-21 09:00' ./scripts/run-hotset-broad-sweep-overnight.sh --run"
```

Attach with `tmux attach -t hotset-broad-v2`. The absolute deadline is a final
safety bound; the controller will stop before starting a pair that cannot fit,
and an uninterrupted maximum-shape run is estimated at 7.47 hours.
