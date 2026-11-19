# Build, run and validate

Run commands from the repository root. Measured hosts use CPUs/ordinary memory
on node 0 and CXL on node 2; inspect `numactl --hardware` on another machine.

## Experimental companion placement

Candidate reporting uses the same policy options and report-path option as
seed reporting. It adds no scoring weights or thresholds:

```sh
opt-18 -load-pass-plugin build-llvm18/lib/ArbiterLLVMPlugin.so \
  -passes=arbiter-report-companion-sites \
  -arbiter-hitm-seed-report-path=companions.csv \
  -disable-output input.bc
```

Pass the same effective seed options used for the workload when comparing
reports. The CSV contains seed/companion IDs, the common worker function,
access kind and loop depth. Reporting does not rewrite or move candidates.
An experiment can union these IDs with the selected seeds and use the existing
`-arbiter-hitm-seed-site-ids` override to build an expanded variant. IDs must be
derived again after changing the source, compiler or optimization settings.

Before a rewritten heap site first allocates, a controller/constructor can call
`arbiter_set_site_placement(site_id, local_node, target_percent, max_target_bytes)`
from `arbiter_runtime_site.h`. For example, 50 with `UINT64_MAX` interleaves
backing over local and target; 100 with `4ULL << 30` grants at most 4 GiB of
target backing, then uses local memory. Both the selected seed policy and any
companion plans must be tested on representative inputs. The API applies a
fixed plan; it does not automatically recognize a workload or measure speedup.
See the [placement contract](overview.md#placement-and-failure-contract).

The retained experiment's `build-variants.py`, `run.py` and `queue.py` automate
candidate extraction, first-touch comparisons, and a training/confirmation
split. Its `ARBITER_EXPERIMENT_PLAN` file loader is linked into experimental
binaries only; it is not a production runtime environment variable.
`emit-plans.py` exports a plan only after independent confirmation, and
`launch-profile.py` applies it only to the exact validated argument list and
binary hash. Unmatched arguments launch the seed-only binary. This fallback
is explicit: an expanded binary with no plan would use target-only placement
for every rewritten site, including companions.

For the retained host and frozen binaries, preview the bounded confirmed plan:

```sh
python3 results/budgeted-companion/20261119/scripts/launch-profile.py \
  --profile results/budgeted-companion/20261119/accepted-plans/screen-h16-cap4g.json \
  --dry-run -- --victims 32 --noise 0 --mode none --duration 30 \
  --table-size 16 --ballast-mb 8192 --read-pct 50
```

Remove `--dry-run` to execute. The profile records absolute paths to the
validated binaries and the measured host's NUMA nodes; it is not a portable
configuration. Rebuild and revalidate after changing binaries, inputs or host.

## Setup and data

[README](../README.md#setup) lists base dependencies and the complete setup.
For a manual compiler/runtime build:

```sh
cmake -S . -B build-llvm18 -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/usr/lib/llvm-18/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/lib/llvm-18/bin/clang++
cmake --build build-llvm18 --target ArbiterLLVMPlugin arbiter_runtime \
  arbiter-runtime-smoke arbiter-slab-arena-smoke
```

MKL defaults to `/opt/intel/oneapi/mkl/latest`; override `MKL_INCLUDE_DIR`,
`MKL_LINK_DIR`, `MKL_RUNTIME_DIR` as needed. `ARBITER_BUILD_DIR` selects the CMake
build; `ARBITER_BENCH_BUILD_DIR` selects benchmark output where supported.
`setup-benchmarks.sh --no-data` skips restoration; `--no-smoke` skips checks.

A and F share `xindex_load_ycsb_a.dat` and `xindex_transaction_ycsb_a.dat`
under `benchmark/xindex/YCSB/xindex_dat/` (about 26 GB uncompressed).
Raw traces are gitignored; compressed `github-parts/` are Git LFS objects.
Choose restoration or import from the local workload checkout:

```sh
git lfs pull
./scripts/restore-xindex-ycsb-data.sh
# Alternative source: ~/niagara_workloads/YCSB/xindex_dat
./scripts/import-niagara-workloads.sh --mode hardlink  # or --mode copy
```

`XINDEX_DATA_DIR` overrides the directory; `YCSB_LOAD_PATH`/`YCSB_TX_PATH`
override individual inputs. `package-xindex-ycsb-data.sh` compresses/splits
traces for LFS (default 1900M chunks). Import/package/restore default to A;
`restore-xindex-ycsb-data.sh --include-archived-b` restores historical B too.

## XIndex A and F

| Command | Purpose |
|---|---|
| `./scripts/run-xindex-a-demo.sh` | Build; one Local/CXL pair, A read/update |
| `./scripts/run-xindex-f-demo.sh` | Build; one Local/CXL pair, F read/RMW |
| `./scripts/run-xindex-evidence-balanced.sh` | One validated A pair using the automatic size-tiebreaker policy |
| `./scripts/run-xindex-hitm-seed-replay.sh --check` | Validate full-run inputs/settings without a benchmark |
| `./scripts/run-xindex-hitm-seed-replay.sh --quick` | One full raw-046 Local/CXL pair |
| `./scripts/run-xindex-hitm-seed-replay.sh` | Four full raw-046 pairs; `REPEATS` overrides count |
| `./scripts/run-xindex-ycsb-f.sh --smoke` | Short F correctness checks |
| `./scripts/run-xindex-ycsb-f.sh` | One validated native/Local/CXL F round; `REPEATS=4` for four |

`--quick` reduces pair count, not trace size. Each full process builds from
100M records and consumes all 400M transactions once, with 31 foreground and
one background worker. There is no duration cutoff or cyclic replay.
Demo scripts take no arguments. F also supports `--check`.
For the general replay, use `ARBITER_CPU_NODE`, `ARBITER_MEM_NODE` and
`ARBITER_TARGET_NODE` to override placement; demo/F convenience scripts fix 0/0/2.

Choose another [policy](../configs/hitm-seed/README.md) and build or replay it:

```sh
ARBITER_HITM_SEED_CONFIG=configs/hitm-seed/candidates/raw-082.config \
  ./scripts/build-xindex-llvm.sh
ARBITER_HITM_SEED_CONFIG=configs/hitm-seed/policy-candidates/published-rmw-size-tiebreaker.config \
  XINDEX_VALIDATE=1 ./scripts/run-xindex-hitm-seed-replay.sh --quick
```

Builds retain `ycsb_bench.sites.csv`, `ycsb_bench.hitm-seed-sites.csv` and
`ycsb_bench.hitm-seed-effective.opt-args`. Timestamped results under
`build/arbiter-bench/` include `runs.csv`, manifests, logs and interpretation.
Use `./scripts/summarize-xindex-hitm-seed-result.sh [RESULT_DIRECTORY]` to
summarize a chosen run or the latest replay. Lower-level process and experiment
controls live in `run-xindex-arbiter.sh` and `run-protected-hitm-seed-experiment.sh`.

F interprets each A UPDATE as same-worker get then put of the same key, counted
as **one logical transaction**. It is not atomic RMW, does not increment the old
value, and is an index-operation replay rather than the full Java YCSB client.
The full trace yields 199,993,860 read-only and 200,006,140 RMW transactions:
400M get calls plus 200,006,140 put calls. A and F rates therefore represent
different amounts of API work. Explicit `READMODIFYWRITE` records work too;
do not reinterpret flattened Java BasicDB F output containing both READ/UPDATE.

## B-tree and coherence microbenchmark

Also install `libomp-18-dev`, `patch`, GNU time and Python 3.9+.
The builder reads `~/vmitosis-workloads` and `~/microbench`; override with
`VMITOSIS_DIR`/`MICROBENCH_DIR`. Adapters patch build copies only. Native and
selected binaries receive identical workload/correctness changes.

```sh
./scripts/build-btree-coherence.sh
./scripts/run-btree-coherence.py
```

Defaults: published-RMW policy, 32 victims, 256 table entries, 50% reads,
8 GiB ballast, no noise, three native/Local/CXL rounds, 120 seconds per micro
row. B-tree completes its fixed 600M lookups; it has **no write-heavy option**.
Automatic selection currently moves no B-tree objects.

For the measured layout/epoch optimization:

```sh
. configs/benchmarks/coherence-throughput.config
./scripts/build-btree-coherence.sh
./scripts/run-btree-coherence.py --benchmark micro --modes local cxl \
  --bin-dir "$ARBITER_BENCH_BUILD_DIR" --rounds 3 --duration 30
python3 scripts/test-coherence-adapter.py "$ARBITER_BENCH_BUILD_DIR"
```

The preset builds 64-byte entries and epoch stores. The default build uses
32-byte entries and epoch stores; `ARBITER_MICRO_EPOCH_STORE=0` gives the
corrected locked-increment control. Build each variant in a separate
`ARBITER_BENCH_BUILD_DIR`. Padding doubles the table, leaving ballast unchanged.

Runner options include `--benchmark btree|micro|both`, `--read-pct 10` for
90% writes, `--table-size`, `--ballast-mb`, `--victims`, `--noise`,
`--noise-mode none|spin|maint|combined`, `--cpu-node`, `--local-node`,
`--cxl-node` and `--result-dir`. `--perf /path/to/perf` counts only the timed
micro phase using acknowledged enable/disable FIFOs. Events target the measured
Intel host; inspect `--help` and event availability on other machines.
`selected-objects.json` connects the build's decisions to live page checks.

## Libcuckoo

The builder fetches upstream commit `0dd0b4d68fef76791a17950fde1a24f2328a58fe`
into the ignored `benchmark/libcuckoo/libcuckoo-upstream/` directory, or checks
`LIBCUCKOO_SOURCE_DIR` is a clean checkout of that revision. It builds upstream's
unmodified `universal_benchmark` and `benchmark/libcuckoo/contention.cpp`, each
as matched native and selected executables. The same published-RMW policy is
used for XIndex, micro and libcuckoo; numeric config values are unchanged.

```sh
./scripts/build-libcuckoo.sh
./scripts/run-libcuckoo.py --result-dir build/libcuckoo-contention \
  --reads 0 --keys 1048576 --hot 65536 --threads 32 --operations 1000000
./scripts/run-libcuckoo.py --benchmark universal \
  --result-dir build/libcuckoo-universal --reads 10 \
  --initial-capacity 23 --prefill 75 --total-ops 1000
./scripts/run-libcuckoo.py --benchmark universal \
  --result-dir build/libcuckoo-insert-erase --reads 0 --inserts 50 --erases 50 \
  --initial-capacity 20 --prefill 50 --total-ops 51200
./scripts/run-libcuckoo.py --benchmark universal \
  --result-dir build/libcuckoo-insert-growth --reads 0 --inserts 100 \
  --initial-capacity 12 --prefill 0 --total-ops 409600
```

Use `ARBITER_BUILD_DIR`, `ARBITER_BENCH_BUILD_DIR` and runner `--bin-dir` for
separate compiler/benchmark builds. Results include exact commands, binary
hashes, raw JSON/stderr and `runs.csv`. Three alternating native/Local/CXL rounds
are the default. Each process runs in a 64 GiB/no-swap systemd user scope, with
CPU/ordinary memory on node 0 and selected objects on node 0 or 2. A selected
run fails validation if no selected allocation executes, private pages appear
on another node, or any residency query fails.

Universal accepts the upstream `--reads`, `--updates`, `--inserts`, `--erases`
and `--upserts` percentages; they must sum to 100. Omitted `--updates` takes the
remaining percentage, preserving the default read/update mix. These are workload
options, not Arbiter selection parameters. Read/update percentages specify
**attempts**; missing-key updates are expected. With capacity `2^23`, prefill 75%,
32 workers and `--total-ops 50000`, only 37.5% of pure update attempts find a
present key. The upstream upsert callback leaves an existing value unchanged.
Use the contention driver with `--reads 0` for guaranteed value increments.
The insert/erase example starts with enough keys that both operations succeed;
the pure-insert example inserts new keys and includes timed table growth.
Pre-generating insert keys uses substantial memory even for bounded table size.
`--total-ops` is a percentage of initial capacity; the resulting request count
must be positive and divisible by workers to avoid upstream's count truncation.
The contention
workload preloads all keys and uses only find/update_fn, with no timed resize.
Every successful update increments a value; after timing, all keys and the
complete value sum are checked against the executed updates. `--hot` controls
the common key set; `--partitioned` splits it among workers (keys are disjoint,
but different keys can still share bucket locks). `--operations` is per worker.
Keys are a contiguous prefix with the standard integer hash, so changing
`--hot` changes spatial locality as well as contention. Setup and validation
are outside timing; releasing the start barrier through joining workers is
timed. Read-only libcuckoo operations still acquire its internal spinlocks.
The example counts are quick checks: for performance comparisons, increase
the fixed count to obtain multi-second runs and keep it identical across modes.

For compiler regression checks, with LLVM 18 tools on PATH:

```sh
./scripts/test-hitm-analysis.py --build-dir build-llvm18
```

This runs the LLVM fixtures and compiles a real std::thread callback/lambda
using list/vector members, including read-only and ambiguous-allocation controls.

## Validation and measurement

Short runtime/compiler checks:

```sh
cmake --build build-llvm18
ARBITER_BUILD_DIR=build-llvm18 ./scripts/smoke.sh
ARBITER_TARGET_NODE=0 build-llvm18/bin/arbiter-runtime-smoke
ARBITER_TARGET_NODE=0 ARBITER_ARENA_REPORT=1 ARBITER_TEST_OBJECTS=40000 \
  build-llvm18/bin/arbiter-slab-arena-smoke
```

`validate-xindex-runtime-correctness.sh` adds ABI/failure-boundary and short
native/Local/CXL semantic checks. Its `-full.sh` counterpart runs one full pair
or `--four-pairs`; the default policy is the explicit site-68+71 ablation.
Set `ARBITER_HITM_SEED_CONFIG` for another policy and `RUN_NATIVE=1` for a baseline.

Performance rows use fresh processes, a 64 GiB systemd memory limit, no swap,
fixed inputs/threads, and no competing benchmark/build. Page caches are left
warm; no system-wide cache flush is performed. Throughput excludes trace loading,
index construction and exit-time reporting. Local and CXL share the same binary.
Use Local/native for rewrite/allocator overhead, CXL/Local for placement, and
CXL/native for end-to-end effect. State whether percentages are ratios of means
or means of paired ratios; they are not interchangeable.

Validation checks exit status, transaction counts, sampled state, selection,
zero fallback/query errors and all located private pages on the target node.
XIndex's current measured loop has no extra per-call success counters; checks
run after timing. A matching 4,096-key digest is sampled evidence, not a complete
linearizability proof. Micro checks actual read/write totals, entry versions,
released locks and epochs. Historical builds and protocols differ: use the
[evidence index](../results/README.md) before comparing retained measurements.
