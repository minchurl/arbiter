# 2026-10-08 Seed-Only `raw-046` Replay

This directory preserves the text evidence for the full-trace regression run
performed after removing use-based member expansion. The run used the new
seed-only policy in `xindex-cxl-arena-seed-size-heavy.config`, which reproduces
the compiler-selected seed fingerprint of the earlier `raw-046` finalist.

## Setup

- Trace: YCSB A, 100M load records and 400M transaction operations
- Measured duration: 180 seconds per process, sampled every 30 seconds
- Workers: 31 foreground and one background worker
- CPU/general memory: node 0
- Compared arena placement: node 0 (local) versus node 2 (CXL)
- Protection: `MemoryMax=64G`, `MemorySwapMax=0`
- Arena: strict mode, 2MiB slabs, 24GiB reserve, 64-byte alignment
- Order and repeats: one local process followed by one CXL process

The compiler selected seed sites `68+71+74+90+97+98+99+100`. Only sites
`68+71+74` allocated from the arena during this trace, exactly matching the
earlier finalist's runtime fingerprint.

## Result

| Placement | Throughput | Max RSS | Arena resident | Majority node |
|---|---:|---:|---:|---:|
| local | 27.8811M op/s | 30.195GiB | 17.310GiB | 0 |
| CXL | 56.9692M op/s | 30.196GiB | 17.310GiB | 2 |

The single-pair CXL-over-local delta was **+104.33%**. The earlier four-pair,
180-second `raw-046` result was 27.886M local, 56.813M CXL, and +103.75% mean
paired delta. The replay differs by -0.02% for local throughput, +0.28% for
CXL throughput, and +0.58 percentage points for the delta.

Both processes completed with status `ok` and exit status zero. Each observed
52,791,182 arena allocations, zero arena fallbacks, zero swaps, and zero
placement-query errors. All 4,537,669 resident arena pages were reported on
the requested node in each process. The six 30-second throughput intervals
also remained stable; the improvement was not produced by a final short
burst.

## Files

- `runs.csv` and `summary.csv`: process-level metrics
- `throughput-samples.csv`: six samples for each 180-second process
- `hotset-input.config`: replay policy
- `hotset-sites.csv`: compiler seed decisions
- `hotset-effective.opt-args`: actual compiler options
- `binaries.sha256`: tested binary hashes
- `logs/*.log`: benchmark and arena reports
- `logs/*.time`: resource and exit-status records
- `artifacts.sha256`: checksums for the archived evidence

## Claim Boundary

This is a one-pair regression check, not a new independent performance study.
It shows that deleting member expansion preserved the earlier seed selection,
runtime placement, safety properties, and approximately 100% throughput
signal under the same full-trace conditions. Statistical confidence still
comes from the earlier four-pair result. As before, this run did not measure
HITM/C2C counters or validate operation results with a final checksum.
