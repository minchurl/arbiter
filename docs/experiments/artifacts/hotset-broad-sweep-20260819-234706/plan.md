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

The controller deterministically generates 80 configurations. The first 12 are
designed anchors, including automatic k1, k2, k3, and k6 references and several
aggressive expansion policies. The remaining configurations vary:

- minimum HITM score and seed count;
- escape, synchronization, worker-reachability, and size weights;
- escape/synchronization requirements;
- dynamic-size inclusion, large-allocation threshold, and size estimate;
- expansion on/off, total-site and per-seed member caps;
- member affinity and call/load traversal depth;
- estimated-byte budget.

`ARBITER_HITM_SEED_SITE_IDS` is empty in every generated config. After each
build, identical selected-site ID sets are collapsed. At most 60 statically
unique binaries enter the screen; build failures and empty selections are
recorded and do not abort the search.

## Adaptive Schedule

One independent observation is one fresh process. Throughput samples inside a
process describe drift; they are not counted as independent repetitions.

| Phase | Candidates | Additional local/CXL pairs | Measured time per row | Sample interval |
|---|---:|---:|---:|---:|
| Screen | up to 60 | 1 | 15 s | 5 s |
| Confirmation | top 10 | 2 (3 total) | 60 s | 10 s |
| Final | top 3 | 7 (10 total) | 180 s | 30 s |

Local-first and CXL-first order alternates between pairs. A native binary runs
only at the start, middle, and end as a machine-drift anchor; it is not rerun
for every parameter configuration.

Screen promotion requires both rows to be `ok`, zero swap/fallback/placement
query errors, local majority residency on node 0, CXL majority residency on
node 2, and the same nonempty runtime allocation-site fingerprint. Policies
with identical runtime fingerprints are collapsed before ranking. This is
important because prior full-trace preflight showed that static k3 and k6 both
executed only site 68, while k1/k2 produced no arena allocation.

The top 10 are ranked by their first paired CXL-over-local throughput delta.
After three total pairs, the top three are ranked by mean paired delta. Final
ranking uses ten total paired fresh processes and also reports sample standard
deviation and CXL win count. Short screening can select candidates, but only
the longer phases should support a performance claim.

## Timing and Failure Handling

At the maximum candidate counts, the estimate is approximately 7.2 hours,
using the observed 65-second full-trace setup cost per fresh process. The
controller has both an eight-hour stop time and an optional absolute deadline.
Before every pair it reserves setup, measurement, cooldown, and finalization
time. It stops cleanly rather than starting a pair that is unlikely to finish.
Each individual row also has a timeout.

OOM, timeout, malformed output, missing arena activity, and compiler failures
are recorded per candidate. They disqualify that candidate but do not discard
the rest of the sweep. `arena-report-missing` is interpreted as a no-activity
result, not as a reason to terminate the controller.

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
OVERNIGHT_END_DEADLINE='tomorrow 09:00' \
  ./scripts/run-hotset-broad-sweep-overnight.sh --run
```

Use tmux for the unattended run; the exact tmux command is given after the
check-only validation.
