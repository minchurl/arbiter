# B-tree and coherence_noise on CXL

## Throughput

The comparison uses the arithmetic mean of three fresh processes per mode.
The CXL/local percentage divides the mean CXL throughput by the mean local
throughput for the same placed executable, then subtracts one.

| Workload | Native | Selected-local | Selected-CXL | CXL vs local | CXL vs native |
|---|---:|---:|---:|---:|---:|
| B-tree, million lookups/s | 23.37 | 22.24 | 10.97 | −50.67% | −53.06% |
| coherence_noise, million operations/s | 350.97 | 351.57 | 351.31 | −0.07% | +0.10% |

B-tree lost 47.81% to 52.61% in the three local/CXL pairs. Every placed run
allocated 48,941,345 key arrays and the same number of pointer arrays. The
arena had 12.03 GiB resident on its requested node at exit. Peak process RSS
was 24.98 GiB native and 25.05 GiB in both placed modes.

Moving the microbenchmark's 8 KiB contended table produced no meaningful
throughput gain. CXL trailed local by 0.20%, 0.01% and 0.01% in the three
pairs. All three CXL runs located the live table on node 2 and the 8 GiB
ballast on node 0. Peak RSS was 8.00 GiB native and 8.05 GiB in both
placed modes.

All 18 measurements passed placement and workload checks. Every selected run
recorded zero arena fallbacks and page-query errors. These are wall-clock
throughput measurements on one host. Identifying a coherence mechanism would
require hardware counters. [Individual runs and page samples](../../results/btree-coherence/20261118/runs.csv)

## Workloads

The supplied B-tree inserts 356,515,840 keys into an order-16 B+ tree. Each
of the 300M timed OpenMP iterations calls `find` twice. Throughput counts
individual lookups and excludes construction and validation. With 32 workers,
the supplied executable completed the lookup loop in 49 seconds, about
12.24 million lookups/s using its whole-second timer. Peak RSS was 34.58 GiB.
The original “0 matches” line sums zero-initialized payloads. The comparison
builds also validate the payload address of 4,096 sampled keys after timing.
The original timed loop shares its RNG state and accumulator across workers
without synchronization, so the lookup sequence can differ between runs.

The supplied microbenchmark command uses 32 victim threads, zero noise
threads, a 50/50 read/write mix, 256 entries of 32 bytes, and 8 GiB of local
ballast. Each operation accesses a table entry, reads a random ballast word,
and advances the worker's epoch. Running the supplied `run.sh` completed
26,452,835,776 operations in 120 seconds, or 220.44 Mops/s, with 8.00 GiB
peak RSS. Its table protocol mixes volatile access and CAS. Its checksum
depends on interleaving and serves as an observable output.

Both supplied programs exited successfully under the same CPU and process
memory bindings as the comparison. The comparisons below use a separate
native control rebuilt from each source with the same Clang flags, linked
libraries, and post-timing probes as its placed binary. The supplied binaries
have a different build and are excluded from the percentage calculations.
[Supplied binary measurements](../../results/btree-coherence/20261118/supplied.csv)

## What Arbiter selected

The evidence-balanced policy selected zero sites in both original sources.
Running its rewrite produced identical LLVM IR for each input after
discarding the printed module filename. B-tree uses `posix_memalign`, which
the compiler pass does not recognize. It reported only deallocations. In
`coherence_noise`, both the table and ballast are dynamic `new[]` sites.
Both scored 2 against a threshold of 5. [B-tree selection report](../../results/btree-coherence/20261118/btree.hitm-seed-sites.csv) · [Microbenchmark selection report](../../results/btree-coherence/20261118/micro.hitm-seed-sites.csv)

The targeted B-tree build calls the existing Arbiter allocation ABI at the
two permanent node-array sites. The 120-byte key arrays and 128-byte pointer
arrays keep their 64-byte alignment. Node headers, records, payload pools and
temporary arrays use the ordinary allocator. The microbenchmark uses Arbiter's
LLVM rewrite with the single site ID resolved from the source location of
`new Entry[]`. Only the 8 KiB table moves. The 8 GiB ballast allocation
stays local.

## Measurement and validation

The November 18, 2026 run used Arbiter's jemalloc runtime from `3a17216`,
built in Release mode. The host has one Xeon Gold 6548Y+ socket with CPUs 0–31 online, Linux
6.6.92+, local DRAM on node 0 and CXL memory on node 2 (`dax0.0`). The
comparison uses Clang 18.1.8, LLVM OpenMP for B-tree, and jemalloc 5.2.1.
All modes bind workers and ordinary allocations to node 0. Each selected
mode uses the same executable with a 24 GiB strict arena on the requested
node. Each process runs in a 64 GiB systemd scope with swap disabled.

Each round runs one workload at a time. The mode order rotates from
native/local/CXL to local/CXL/native to CXL/native/local. The runner uses
the workloads' internal timers and queries live addresses with `move_pages`
after timing. B-tree probes the root and two leaves' arrays plus three
payload addresses. The microbenchmark probes the first, middle, and last
entries of the table and ballast before freeing them. The exit-time arena
scan also includes allocator metadata and may run after application frees.
The report accepts a selected row only if every resident arena page is on
the target node, with zero query errors and allocator fallbacks.

Reproduction commands and source-directory overrides are in the
[project README](../../README.md#run-b-tree-and-the-coherence-microbenchmark).
For these historical explicit-placement measurements, use
[commit a2151db](https://github.com/minchurl/arbiter/tree/a2151db) and build with
`ARBITER_BENCH_SELECTION=targeted` and
`ARBITER_HITM_SEED_CONFIG=configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config`.
The supplied B-tree checkout was based on `25b5ede` with local source edits.
The input manifest identifies the source files and binaries used for these
measurements by hash. [Input hashes](../../results/btree-coherence/20261118/inputs.sha256)
