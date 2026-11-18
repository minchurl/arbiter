# Coherence microbenchmark tuning — 2026-11-18

This experiment separates allocation placement from improvements to the
microbenchmark itself. The automatic published-RMW policy still selects only
`g_table` (site 4). It keeps the read-only ballast local. No compiler policy,
runtime allocator, or XIndex source was changed in this experiment.

## B-tree write workload

The supplied `vmitosis-workloads/bin/bench_btree_mt` has no read/write-ratio
option. Its common driver accepts placement/output options, while `real_main`
ignores workload arguments. All inserts precede the timer; the timed OpenMP
loop performs two `find` calls per iteration. The old introductory
`bpt [order]` comment does not describe this workload's current main function.

Insertion/deletion functions exist, but they do not provide synchronization
for concurrent structural changes. Adding writes safely would require a new
workload and a concurrency protocol. Atomic payload updates would be a
separate experiment: they would write payload allocations, not the key and
pointer arrays selected in the earlier targeted-placement experiment.
There is no existing write-heavy preset to enable for this executable.

## What moves, and why it might experience HITM

| Object | Placement | Sharing during measurement |
|---|---|---|
| `g_table`, site 4 | Local or CXL arena | All victims access random entries. Writes acquire a CAS lock, update the value and release a version. True sharing occurs on the same entry; the 32-byte layout also allows adjacent-entry false sharing. Maintenance readers add sharing. |
| `g_ballast`, site 5 | Local DRAM | Initialized once, then read only. It generates cache misses and memory traffic but has no continuing writer to cause HITM. |
| `vector<VictimResult>` | Local DRAM | Workers accumulate counts/checksums in local variables and publish results once at exit. Adjacent results are not a hot shared write path. |
| Victim/noise `std::thread` state and handle-vector storage | Local DRAM | Thread setup, private callable arguments and teardown. No repeated shared mutation in the benchmark's timed operation loop. |
| `g_epochs` | Static storage; not an allocation site | One writer per cache-line-aligned counter. Maintenance workers read them during barriers. With maintenance disabled, other workers do not read these counters in the timed loop. |
| Start/stop/ready flags and spin flag | Static storage; not an allocation site | Primarily startup/shutdown coordination. The spin flag stays read-only until shutdown. |

The supplied 256-entry table occupies 8 KiB at 32 bytes per entry and 16 KiB
at 64 bytes. Ballast remains 8 GiB in the main comparisons. Write percentage,
worker count, noise mode and table size do not change which allocation moves.
Padding changes the size of that allocation, not its identity.

Static RMW evidence identifies a candidate, not a guaranteed placement
benefit. For example, `--read-pct 100` leaves the table read-only during
measurement, although the binary still contains the write branch and the
static policy still selects its allocation.

## Correctness and optimization changes

The adapter modifies copies under the build directory; supplied sources stay
unchanged. Both native and placed executables receive the same changes.

- Preserve a 64-bit read threshold: the original 32-bit conversion made
  `--read-pct 100` overflow to zero and execute writes.
- Reject an already-held lock before CAS. The original CAS could succeed
  with identical locked expected/desired values, admitting multiple writers.
- Use atomic value/status accesses and retry inconsistent reads. The spin
  flag and maintenance reads also use atomic accesses.
- Validate, outside timing, that summed entry versions equal completed
  writes, no lock remains held and every epoch equals its worker's count.
  Report actual read/write counts; reject invalid CLI parameters.
- Replace single-writer epoch `fetch_add` with an atomic store of the same
  per-operation progress. Keep `ARBITER_MICRO_EPOCH_STORE=0` as a corrected
  locked-increment control.
- Offer 64-byte entries with `ARBITER_MICRO_ENTRY_BYTES=64`; check their table
  alignment at runtime. Default 32-byte entries retain the original false
  sharing experiment. Padding retains same-entry sharing and doubles table
  bytes, while leaving the logical workload unchanged.
- Offer `ARBITER_MICRO_FAST_INDEX=1`: snapshot immutable table/ballast
  pointers and sizes, and use masks for power-of-two lengths. Non-power-of-two
  lengths still use modulo. Every PRNG draw and resulting random index is
  preserved. This option defaults to zero so its effect can be measured
  separately.

The previous published measurements used the supplied synchronization
implementation. They remain historical evidence, not a correctness baseline
for the repaired benchmark.

## Measurements

All comparisons used the Xeon Gold 6548Y+ host, 32 online CPUs on node 0,
local DRAM on node 0 and CXL on node 2, Clang 18.1.8, and the Release jemalloc
runtime. Each run was a fresh process inside a 64 GiB scope with swap disabled.
The main comparison keeps 32 victims, 256 entries, 50% reads, 8 GiB ballast and
no noise. Three pairs per variant ran for 30 seconds each, reversing both case
and placement order on alternate rounds. These throughput runs did not use
performance counters.

| Variant | Local Mops/s | CXL Mops/s | CXL / local change | Local / corrected change |
|---|---:|---:|---:|---:|
| Corrected, 32-byte entries, epoch RMW | 347.79 | 353.73 | +1.71% | +0.00% |
| 32-byte entries, epoch store | 375.10 | 375.46 | +0.10% | +7.85% |
| 64-byte entries, epoch store | 541.70 | 538.32 | -0.63% | +55.76% |

The first corrected-local run was 336.14 Mops/s; its next two runs were
353.77 and 353.46. All three are retained. Corrected-CXL runs were
353.57–353.91, so the apparent +1.71% average placement gain is driven by the
first local result and did not repeat. The epoch-store and padded comparisons
show no useful CXL gain. Relative to the latter two corrected-local runs,
padding plus epoch stores improves local throughput by about 53%.

The table doubles from 8 KiB to 16 KiB with padding. Peak process RSS remains
about 8.05 GiB because the 8 GiB ballast dominates memory use. All selected
live-page samples matched the target node; ballast stayed on node 0.
[All 18 main measurements](../../results/coherence-tuning/20261118/confirm.csv)

An additional three pairs per variant, 20 seconds per process, tested fast
indexing with a freshly built padded control. The workload stayed identical
and the table remained the only selected allocation.

| Variant | Local Mops/s | CXL Mops/s |
|---|---:|---:|
| fast-control | 541.72 | 537.53 |
| fast-index | 483.61 | 487.59 |
| fast-packed | 339.51 | 339.27 |

`fast-control` uses 64-byte entries, epoch stores and ordinary modulo.
`fast-index` enables cached metadata and power-of-two indexing with 64-byte
entries. `fast-packed` enables that indexing with 32-byte entries. Fast
indexing regressed the padded control by 10.73%
local and 9.29% CXL. It remains off in the recommended preset and
is retained only as an explicit experimental comparison. The experiment does
not identify which generated-code or contention change causes that regression.
[All 18 arithmetic-comparison rows](../../results/coherence-tuning/20261118/fast.csv)

The earlier screen ran 21 configurations for six seconds per process, one
local/CXL pair each. It explored 0/10/50/90/100% reads, no ballast or 8 GiB
ballast, 16/32 victims, maintenance/combined noise, table sizes 16 through
1,000,000, and 32/64-byte entries. No configuration demonstrated a repeatable
CXL benefit. The 32 MB table's CXL rate was 261.40 versus 764.53 Mops/s local
(−65.81%). The supplied-size small-table differences were mostly within 1%.
The initial corrected-local screen row was also slower; it is retained.
[All 42 exploratory measurements](../../results/coherence-tuning/20261118/screen.csv)

The screen preceded final diagnostic instrumentation; input and binary hashes
are retained separately for every build. The main and arithmetic confirmations
use their respective matched final builds, rather than mixing screen rows
into their averages.

## Counter interpretation

Separate 15-second runs counted only the hot phase, excluding initialization,
page probes and validation. Every event reported 100% running time. The
read-only control uses 256 entries; the large-table case uses 1,000,000
entries and 90% writes. Other settings match the main comparison.

| Variant | HitM loads/op, local | HitM loads/op, CXL | Locked loads/op, local | Cycles/op, local | Cycles/op, CXL |
|---|---:|---:|---:|---:|---:|
| corrected | 0.4332 | 0.4327 | 1.5130 | 315.4 | 315.4 |
| epoch-store | 0.4262 | 0.4271 | 0.5142 | 297.0 | 297.4 |
| padded | 0.3788 | 0.3731 | 0.5165 | 210.0 | 208.8 |
| read-only | 0.0037 | 0.0038 | 0.0000 | 113.5 | 114.2 |
| large-table | 0.1604 | 0.1168 | 0.9000 | 155.4 | 484.1 |

Replacing the epoch RMW removes approximately one locked operation per
logical operation. Padding reduces the measured HitM loads per operation,
while substantial same-entry sharing remains. Moving the small table to CXL
does not materially reduce these events. With the 32 MB table, lower HitM
counts coexist with 719.13 local versus 230.95 CXL Mops/s (−67.89%). A lower
HitM count alone therefore does not establish a faster placement.
[Event counts and normalization](../../results/coherence-tuning/20261118/counters.csv)

Five additional 10-second PEBS sampling runs used the same measurement-window
control and a period of 100,003 events. In the four mixed-read/write runs,
99.65–99.88% of sampled HitM load addresses were inside the table, and every
sampled L3-miss address was inside the ballast. No samples mapped to the
epoch array. This directly supports selecting the table as the coherence-risk
object and leaving the read-only traffic region local. It is consistent with
the small table remaining cache-resident while its ownership moves between
cores; backing-page placement does not remove those transfers.

The read-only control recorded one table HitM sample and 351 ballast HitM
samples, versus 97,542 ballast L3-miss samples. There are no timed table or
ballast writes in that control. These residual event counts are not evidence
of a continuing shared-writer workload in the ballast; source access patterns
and the operation mix remain necessary when interpreting the counter.
[Address-attributed samples](../../results/coherence-tuning/20261118/hitm-samples.csv)

Raw sampling files and logs remain under `build/micro-tuning/samples`.
To reproduce the sampling event setup, use `perf record` with
`-e mem_load_l3_hit_retired.xsnp_fwd:upp,mem_load_retired.l3_miss:upp`,
`-c 100003 -d -D -1 --control fifo:CONTROL,ACK`; set
`ARBITER_MICRO_PERF_CONTROL=CONTROL` and `ARBITER_MICRO_PERF_ACK=ACK`
for the benchmark. Map `perf script -F event,addr` addresses to the live
`objects:` ranges printed by the executable.

The L3 HitM event is `mem_load_l3_hit_retired.xsnp_fwd`, described by Intel as
retired loads served by HitM responses from shared L3. It is not a count of
all possible coherence transactions or CHA interrupt events.
[Intel Emerald Rapids event definitions](https://perfmon-events.intel.com/platforms/emeraldrapids/core-events/core/)

Cache-line sharing requires multiple CPUs accessing a line with at least one
writer. Padding can address adjacent-object sharing but cannot eliminate
same-object contention. Moving a small hot table's backing pages to CXL does
not by itself remove ownership transfers between CPU caches.
[Linux false-sharing documentation](https://www.kernel.org/doc/html/latest/kernel-hacking/false-sharing.html)

## Reproduction and validation

For the recommended settings, source the preset from the repository root:

```sh
. configs/benchmarks/coherence-throughput.config
./scripts/build-btree-coherence.sh
./scripts/run-btree-coherence.py --benchmark micro --modes local cxl
```

This preset enables 64-byte entries and epoch stores, retains the published-RMW
allocation policy and leaves fast indexing disabled. It improves workload
throughput; it does not promise a CXL placement speedup.

Build the three main variants separately, using a Release compiler/runtime
build. Default source locations are `~/microbench` and `~/vmitosis-workloads`.

```sh
for variant in corrected epoch-store padded; do
  bytes=32
  store=1
  if [ "$variant" = corrected ]; then store=0; fi
  if [ "$variant" = padded ]; then bytes=64; fi
  ARBITER_BUILD_DIR=build-release \
    ARBITER_BENCH_BUILD_DIR="build/micro-tuning/final-$variant" \
    ARBITER_MICRO_ENTRY_BYTES="$bytes" ARBITER_MICRO_EPOCH_STORE="$store" \
    ./scripts/build-btree-coherence.sh
done
python3 scripts/run-coherence-sweep.py \
  results/coherence-tuning/20261118/confirm-cases.json \
  --build-root build/micro-tuning --result-dir build/my-confirmation \
  --rounds 3 --duration 30
```

For the additional arithmetic optimization, build `fast-control` with 64-byte
entries and fast indexing disabled, `fast-index` with 64-byte entries and
fast indexing enabled, and `fast-packed` with 32-byte entries and fast indexing
enabled. All three use epoch stores. Run the retained `fast-cases.json` with
three rounds of 20 seconds.

To run the original size/mix with heavier writes:

```sh
./scripts/run-btree-coherence.py --benchmark micro --read-pct 10 \
  --bin-dir build/micro-tuning/final-epoch-store \
  --modes local cxl --rounds 3 --duration 30
```

`--read-pct 10` means 10% reads and 90% writes. The six-second screen is
exploratory; changing the read mix, table size or ballast changes the workload,
so a higher rate in those rows is not a speedup on the supplied workload.
The raw cases and every successful row are retained in the linked results.

Use `--perf /path/to/perf` with the sweep or microbenchmark runner to capture
only the measurement window. The build copy sends acknowledged enable/disable
commands over FIFOs, outside timing. Both the 4-byte and NUL-terminated perf
acknowledgement formats are accepted. The original host's `/usr/bin/perf`
wrapper lacks the custom kernel package; these measurements use
`/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf` (6.8.12).

All 88 recorded sweep/confirmation/counter runs passed operation-count,
version-total, live placement, arena residency, zero-fallback and zero-swap
checks. All six native/placed builds in the main comparison passed contention
checks on one entry, 0/50/100% reads, maintenance/spin workers and invalid CLI
inputs. The fast-index build passed the same checks plus a 257-entry, 3 MiB
ballast run, exercising both non-power-of-two modulo fallbacks.

A GCC 11 ThreadSanitizer build completed a two-second test with four victims,
16 entries, two maintenance workers and one spin worker without a race report.
The source changes to atomic value/status accesses and the spin flag were
included. [TSan output](../../results/coherence-tuning/20261118/tsan.log)
[Per-run write-count validation](../../results/coherence-tuning/20261118/validation.csv)

The recommended preset also passed a three-mode native/local/CXL smoke run.
Its executable text matches the measured `fast-control` build. Shell/Python
syntax checks and `git diff --check` passed. The retained XIndex executable
still hashes to
`e94972432898885a4904acd571ea5bbe7fef478773e14a4705576d75695dffc7`.
No additional XIndex timing claim is made from this microbenchmark experiment.

All changes are benchmark adapters, runners, tests, and documentation. The
XIndex binary and allocation policy are unaffected; the previous four-pair
YCSB-A preservation result remains the relevant XIndex evidence.
[Previous XIndex confirmation](published-rmw-policy.md#xindexycsb-a-preservation)
