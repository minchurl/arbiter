# XIndex/YCSB-B Adaptive Hot-Set Sweep

This experiment re-evaluates the 100 parameter configurations from the
completed YCSB-A broad sweep with the current seed-only compiler and the
full YCSB-B trace. It does not restore member expansion or pin site IDs.

## Schedule

1. Rebuild all 100 archived `raw-*.config` inputs with the current compiler.
2. Reject build failures, selected dynamic-size allocations, and policies
   without a selected seed. Record and skip duplicate static seed sets because
   those configurations produce the same rewritten placement policy.
3. Screen every remaining static-unique policy on YCSB-B with one local/CXL
   pair.
4. Promote up to ten policies, retaining at most two policies per runtime
   allocation-site fingerprint, and run two additional YCSB-B pairs.
5. Promote up to three policies, retaining at most one policy per runtime
   fingerprint, and run four fresh local/CXL pairs on both YCSB-A and YCSB-B.
6. Run four native rows for each final workload.

Every row is a fresh process. It reads the 100M-record load trace, constructs
and trains XIndex, then consumes its 400M-operation transaction trace exactly
once. `XINDEX_ITERATION=1` and `XINDEX_DURATION_SECONDS=0`; the controller does
not terminate a row after a measured duration. The eight-hour budget only
prevents admission of a new pair when insufficient time remains.

The local and CXL rows use the same rewritten binary and strict arena. Only the
arena node changes between node 0 and memory-only node 2. Ordinary XIndex
memory and 31 foreground plus one background worker remain on node 0.

## Controls

| Control | Value |
|---|---|
| Inputs | 100M load; 400M YCSB-A and YCSB-B transactions |
| Screening workload | YCSB-B |
| Final workloads | YCSB-A and YCSB-B |
| CPU / ordinary memory / CXL | node 0 / node 0 / node 2 |
| Arena | strict, 2MiB slabs, 24GiB reserve, 64B alignment |
| Process protection | `MemoryMax=64G`, `MemorySwapMax=0` |
| Process state | fresh process per row |
| Filesystem cache | warm; no `drop_caches` |
| Placement order | local/CXL order alternates by pair |

The script builds all 100 inputs, but benchmark row count is normally much
smaller after static de-duplication. The previous reports imply roughly 21
distinct fixed-size seed sets under the seed-only compiler. The preflight
prints a conservative 296-row, 7.6-hour upper bound before de-duplication;
the expected run is closer to three or four hours.

## Run

From the repository root, validate without building or running:

```sh
./scripts/run-xindex-ycsb-b-adaptive-sweep.sh --check
```

Start the unattended run in tmux:

```sh
tmux new-session -d -s xindex-ycsb-b-sweep -c "$(pwd)" \
  './scripts/run-xindex-ycsb-b-adaptive-sweep.sh --run'
```

Inspect progress with:

```sh
tmux attach -t xindex-ycsb-b-sweep
```

The controller does not move OS or editor processes away from node 0. Keep the
machine quiet during the run. It also does not drop filesystem or CPU caches.

## Results

The timestamped result directory is under
`build/arbiter-bench/xindex-ycsb-b-sweep-*`. Important files are:

- `manifest.txt`: exact environment and experiment shape;
- `builds.csv`: all 100 build/static-analysis outcomes;
- `selected-configs.csv`: static-unique policies that entered screening;
- `observations.csv`: every process-level measurement and safety field;
- `screen-summary.csv` and `screen-ranking.csv`;
- `confirm-summary.csv` and `confirm-ranking.csv`;
- `finalists.txt`;
- `final-summary.csv` and `native-summary.csv`;
- `summary.md`: concise final A/B comparison;
- `sweep-console.log`: controller progress and failures.

Promotion requires successful rows, identical local/CXL runtime fingerprints,
zero swap, zero arena fallback, zero placement-query errors, and residency on
the requested NUMA node. The final tables report mean throughput, mean paired
CXL-over-local delta, sample standard deviation, wins, RSS, and CXL-resident
arena bytes. Screening results are exploratory; the four fresh final pairs are
the intended source of a confirmed effect size. If no policy passes promotion,
screening supports only a directional workload-level conclusion.

## 2026-10-08 result and conclusion

The completed run used
`build/arbiter-bench/xindex-ycsb-b-sweep-20261008-085548`; its reportable
outputs are preserved in
[`artifacts/xindex-ycsb-b-sweep-20261008-085548`](artifacts/xindex-ycsb-b-sweep-20261008-085548/README.md).
This is the sole YCSB-B result retained for reporting; later focused or
allocator-alignment exploration is not part of this result.

- All 100 archived parameter configurations were evaluated: 21 unique safe
  placement policies were selected, 62 were static duplicates, 12 selected
  non-constant-size sites, four selected no site, and one failed to build.
- The run recorded 42 screening rows (21 local/CXL pairs), plus four native
  rows for each of YCSB-A and YCSB-B.
- Fifteen local/CXL pairs passed the strict runtime safety and comparability
  checks. Every valid pair regressed with CXL: paired deltas ranged from
  -19.18% to -45.34%, so no candidate was promoted to confirmation.
- Six policies produced no runtime arena allocation and were excluded rather
  than treated as positive CXL results.
- No row used swap or encountered OOM. Maximum RSS was approximately 33.3 GiB
  under the 64 GiB hard limit.
- The four native YCSB-B rows averaged 99.16 M op/s. The trace contained about
  380 million reads and 20 million updates (95% reads, 5% updates).

For this XIndex/YCSB-B setup, moving selected objects to CXL did not improve
throughput. The workload performs too few writes for the measured
cache-coherence benefit to offset the added CXL access cost. This supports a
narrow claim about this benchmark and machine configuration, not a general
claim that placement cannot help every read-heavy workload.

Because no policy passed the screening promotion threshold, the planned
multi-pair confirmation and final A/B stages did not run. Accordingly, the
direction is consistent across all valid screening pairs, while the exact
regression of any individual configuration should not be presented as a
confirmed effect size.
