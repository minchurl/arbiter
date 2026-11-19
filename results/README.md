# Retained evidence

Read [conclusions](../docs/results.md) first. This directory keeps original
measurements, validation extracts, configs and hashes; current commands are in
[the benchmark guide](../docs/benchmarks.md). Historical results are not reruns
of today's runtime. Directory names below link to the retained data directly.

## Latest allocator and benchmark comparisons

| Directory | Scope / principal files |
|---|---|
| [adaptive-companion/20261119](adaptive-companion/20261119/) | Online companion placement without input profiles: automatic progress discovery, shared probe/rollback policy, whole-run results, condition-change diagnostics and full XIndex correctness pair. `summary.csv`, `controller-summary.json`, `frozen.json`, `audit.json`, `adaptive-results.png`, `adaptive-phase.png`. |
| [budgeted-companion/20261119](budgeted-companion/20261119/) | Historical companion replay, common-loop candidates, runtime first-touch interleave/caps, fresh micro confirmations and full XIndex regression. `summary.csv`, `decisions.json`, `accepted-plans/`, `budget-checks.csv`, `audit.json`, `final-selection-checks.json`, `performance.png`. |
| [companion-placement/20261119](companion-placement/20261119/) | Frozen-code libcuckoo lock/bucket ablations, micro partial-ballast placement and refinement, fresh confirmations and full XIndex A regression. `summary.csv`, `placement-validation.csv`, `mechanism-summary.json`, `audit.json`, `checks.json`, `performance.png`, `placement-window.png`. |
| [placement-causality/20261119](placement-causality/20261119/) | Unchanged XIndex binaries: reversible cold-buffer and hot-page placement in the same process, phase-aligned retry/latency profiles, and libcuckoo cache controls. `phases.csv`, `mechanism-summary.json`, `cache-summary.csv`, `checks.json`, `placement-crossover.png`. |
| [write-heavy-20261119](libcuckoo/write-heavy-20261119/) | Unchanged libcuckoo binaries: successful 100% updates, insert/erase and insertion with/without growth; paired placement comparisons, separate lock diagnostics and runner validation. `runs.csv`, `summary.csv`, `checks.json`, `raw-runs.jsonl.gz`. |
| [placement-diagnosis/20261119](placement-diagnosis/20261119/) | Frozen-code XIndex/micro bottleneck comparison, precise retry/address samples, allocation and isolated extent-placement ablations. `runs.csv`, `mechanism-summary.json`, `checks.json`, `manifest.json`, `performance.png`. |
| [object-rmw-20261119](libcuckoo/object-rmw-20261119/) | Object/member RMW and std::thread extension; full XIndex A and micro regressions; original libcuckoo placement comparisons and isolated TTAS/padding experiments. `placement-summary.csv`, `algorithm-summary.csv`, `regression-validation.json`, `manifest.json`. |
| [jemalloc-strict-20261119](xindex/ycsb-a/jemalloc-strict-20261119/) | Final 650-line runtime: one full A Local/CXL pair, no fresh controls. `runs.csv`, `manifest.json`, `validation.txt`, `checks.txt`, `code-size.csv`, `selected-sites.csv`. |
| [jemalloc-demand-20261118](xindex/ycsb-a/jemalloc-demand-20261118/) | Bounded vs initial 1,002-line demand runtime: four runs per allocator/placement, 16 total. `runs.csv`, `lifecycle.csv`, hashes/environment, code counts. Intermediate strict-only checks are not performance rows. |
| [jemalloc-20261117](xindex/ycsb-a/jemalloc-20261117/) | Custom slab vs bounded jemalloc: eight full A rows in `runs.csv`; five processes per cell in `arena-smoke.csv`. |
| [coherence-tuning/20261118](coherence-tuning/20261118/) | Corrected microbenchmark: layout/epoch improvements, counter evidence and negative screens; see file map below. |
| [published-rmw-20261118](allocation-policy/published-rmw-20261118/) | `decisions.csv`, `screen.csv`, `benchmark-runs.csv`, `xindex-runs.csv`, hashes. Automatic table selection and four A pairs per policy; original, not corrected, micro synchronization. |
| [btree-coherence/20261118](btree-coherence/20261118/) | Historical explicit-placement experiment: three native/Local/CXL runs per benchmark (`runs.csv`), separate supplied binaries (`supplied.csv`), reports/hashes. Original micro synchronization. |

For online adaptive placement, the final frozen binaries run 34 micro processes:
nine each for the 16/256-entry confirmations, two each for the 8/32-entry
neighbors, three each for the short 16/256-entry checks, two for the CPU-affinity
condition change, and four for the 100%-read holdout. Two full 400M-transaction
XIndex processes are a separate prior/current correctness and regression
diagnostic, not a statistically established performance comparison. Six pilot
processes, a final six-second observer smoke, and two GDB page diagnostics are
excluded from throughput conclusions. An interrupted short-workload comparison
is also excluded in full and rerun: five processes, including two foreign-CPU
rejections, two controls, and a shutdown-validation assertion. Any other CPU-guard-rejected attempts remain
in the raw archive. This is a monitored shared host, not an exclusive reservation.

The primary comparison is **observe versus adapt in the same binary**. A plain
companion-local binary is also retained, but link/address/layout effects prevent
its difference from being interpreted as the observer thread's isolated cost.
The timed throughput includes warmup, probes, page query/migration/verification,
settling and rollback. Launcher wall-rate comparisons also include initialization
and shutdown. `controller-summary.json` retains steady monitoring rates separately;
do not replace the whole-run result with a peak window.

`frozen.json` records sources, binaries and the one shared controller policy;
`shared-policy.json` verifies identical seed options across the three programs.
`worker-equivalence.json` proves matching 149-instruction micro workers. XIndex
and libcuckoo have no suitable companion domain and retain seed-only IR with no
adaptive observer. `build-checks.json` records final tests; `build.json` preserves
an initial rejected toolchain configuration as history and points to the successful
final build. Intermediate prototype snapshots are debugging evidence, not exact
source manifests for every pilot executable. The holdout only adds an evaluation
runner read-percentage option after freezing measured code; the earlier runner
is retained as `driver-before-read-option.py` in the raw tools evidence.
`final-build-config.json` records the successful toolchain cache, and
`reproduction.json` verifies byte-identical regeneration of all nine rewritten
bitcode/linked executable outputs after the final throughput measurements.
`shutdown-validation.json` explains the later harness correction: a cancelled
atexit migration can encounter pages purged by benchmark teardown. Such events
are recorded separately, with valid final work counts and the byte cap still
required. Every live completed migration must have zero failed/missing/mismatched
pages. Measured compiler/runtime/binary files did not change. The earlier driver
and interrupted queue logs remain in raw evidence; `resume-queue.py` records the
fresh comparisons after the interruption.

The controller discovers sites/progress automatically; there is no benchmark-name,
table-size, read-ratio or application-symbol lookup in it. The separate page-query
diagnostic uses benchmark symbols to validate every object page, and is excluded
from performance comparisons. Its final snapshots complement the controller's
per-migration checks; they do not prove every page stayed on a node at every
instant. The 4 GiB cap covers current resident companion backing, including
allocator metadata, and excludes seed pages.

```sh
python3 results/adaptive-companion/20261119/scripts/extract-raw.py confirm-h16 /tmp/arbiter-adaptive-h16
python3 results/adaptive-companion/20261119/scripts/summarize.py --base results/adaptive-companion/20261119
python3 results/adaptive-companion/20261119/scripts/plot.py --base results/adaptive-companion/20261119
```

Extraction refuses an existing output directory. Summary/plot regeneration reads
the archive; plotting needs Matplotlib. Other scripts preserve this host's
toolchain, paths and earlier frozen build inputs, which must be prepared before
replaying the recorded build commands into fresh directories. `queue.py`, `after.py`
and `holdout.py` record the sequential scheduling; they are not generic job runners.
`raw-files.jsonl.gz` preserves logs/commands/events/host guards losslessly and
`artifacts.sha256` covers the archive. The [Korean report](../docs/results.md#online-companion-placement-november-19)
states positive results, exploration losses and the current limits of generality.

For budgeted companion placement, 92 accepted processes cover eight cases:
14 each for the 16/256-entry screens, 25 fresh 16-entry confirmations, six
default-micro regressions, nine full XIndex regressions, 12 historical XIndex
companion screens, and six each for the 8/32-entry exploratory screens.
Every XIndex process replays 400M timed transactions with a validated digest.
Twelve CPU-guard-rejected attempts and a six-run initial pilot affected by
another benchmark are retained but excluded. The first screen used a stricter
foreign-CPU threshold than subsequent cases; per-attempt manifests preserve
that protocol difference. This was a monitored shared host, not an exclusive
reservation, and brief background-service bursts can remain.

`summary.csv` separates screens from confirmations and includes paired intervals
and whole-launcher amortized throughput. `accepted-plans/` contains the
confirmed 50% plan and the independently confirmed 4 GiB bounded alternative.
The profile launcher validates exact arguments and artifact hashes, and selects
the seed-only binary for an unmatched input. It is an offline profile policy,
not online workload detection or throughput feedback. The budget is per-site
lifetime target backing, not total-process CXL RSS.

`final-selection-checks.json`, `reproduction.json`, `audit.json` and
`micro/worker-equivalence.json` establish unchanged seed reports, identical
rebuilt binaries, frozen benchmark/input files, and unchanged timed worker
instructions. `checks.json` and `launcher-checks.json` record LLVM, runtime,
concurrent-cap/failure-path and profile-launch tests. The four diagnostic
placement runs in `page-validation/summary.json` query every object page before
and after timing, with zero errors and stable residency hashes; they are not
performance rows. No new PMU evidence is claimed for the speedup's mechanism.

Restore original command records, logs, CPU-guard records, placement checks,
compiler reports and source extracts from the lossless `raw-files.jsonl.gz`:

```sh
python3 results/budgeted-companion/20261119/scripts/extract-raw.py confirm-h16 /tmp/arbiter-confirm-h16
python3 results/budgeted-companion/20261119/scripts/summarize.py --base results/budgeted-companion/20261119
python3 results/budgeted-companion/20261119/scripts/plot.py --base results/budgeted-companion/20261119
```

The extraction destination must not exist. Summarization and plotting use the
archived rows; plotting requires Matplotlib and NumPy. Build/runner scripts
retain this host's tool paths and frozen build inputs, and require fresh output
directories for a new experiment. `artifacts.sha256` covers the archived files.

For the earlier companion placement experiment, each case retains its workload/binary manifest and
per-process CSV: 134 screen rows, 125 fresh confirmation rows, 9 PMU rows and
6 full XIndex runs, plus the separate nine-phase crossover. `raw-files.jsonl.gz` stores the original command records,
logs, GDB command files, NUMA snapshots, page-validation JSON and perf output
as `{case, file, text}` records. Restore a case with
`python3 results/companion-placement/20261119/scripts/extract-raw.py CASE OUTPUT`.
The output directory must not already exist. Micro's complete before/after
page checks are summarized in `placement-validation.csv`; the recorded seed,
page count and index hash reproduce each random subset without storing millions
of addresses. In per-process comparisons, migration changes physical placement
before timing. `crossover-micro/phases.csv` is a separate same-process diagnostic:
only ballast pages migrate between phases; the table stays in CXL. Existing
per-worker epoch counters supply operation counts through read-only snapshots.
Migration and three subsequent seconds are excluded. Fifteen-second PMU windows
use the enclosing snapshot interval as an approximate operation denominator.
These phases are not independent process confirmations.

Do not pool screens with confirmations. Micro confirmations use the original
automatic-selection binary; libcuckoo confirmations are untraced. The initial
screens use allocation-only variants and GDB; all timed worker instructions
are verified equivalent. `confirmation-plan.json` records candidate selection,
`confirmation-binaries.json` explains the original-layout control, and
`refinement-plan.json` records the wider fraction search after the first positive
confirmation. `generalization.json` records the existing policy's limits. Probes and PMU
diagnostics are excluded from confirmed throughput comparisons.

Regenerate tables with `scripts/summarize.py --base results/companion-placement/20261119`
and diagnostic interpretations with `scripts/summarize-mechanism.py --base results/companion-placement/20261119`.
Regenerate figures with `scripts/plot.py --base results/companion-placement/20261119`,
using the scripts inside that archive. Matplotlib and NumPy are needed for the
figure. The build/runners preserve this host's LLVM, GDB and retained build
paths; prepare matching frozen inputs before replaying them into fresh result
directories. The stage controllers record the original sequential scheduling
and should not be run blindly with historical process IDs.

For placement causality, every XIndex case retains its exact `driver.py`,
command/environment manifest, original output, resolved hot objects, migration
status hashes, clock alignment and phase summary. `page-sets.rle.json.gz` is a
lossless encoding of the original page sets: each run is a first byte address
and count of consecutive 4 KiB pages; initial-node runs add the NUMA node.
Hashes of the original JSON and gzip files are retained. No benchmark contents
are written: only physical placement changes through `move_pages`.

`phases.csv` includes the initial hot-page probe separately by case name.
Duration replay, unprofiled interventions and PMU diagnostics are not pooled
with previous fixed-count throughput confirmations. Rejected discovery/timing
and perf-shutdown probes retain their logs and `rejected.json` explanations;
they are excluded from the phase summary. The shutdown probe was rerun after
accepting perf's expected SIGINT exit, with complete benchmark validation.
Valid profiles retain compressed decoded samples, event periods, zero-loss
checks, per-phase thread IDs and derived event/latency tables. Latency weights
are conditional on the sampling threshold, not the mean of all loads. Raw perf
files remain in ignored build storage with hashes in `checks.json`.

Run `python3 results/placement-causality/20261119/scripts/summarize-mechanism.py`
and `python3 results/placement-causality/20261119/scripts/plot.py` to regenerate
the derived mechanism/cache tables and figure from this archive. Individual
phase CSVs can be regenerated by passing case directories to
`scripts/summarize-phases.py`. Other scripts preserve the measured host's paths
and frozen binaries under `build/placement-diagnosis/placements/` and
`build/libcuckoo-rmw/bench-final/`; they require fresh case directories.
Historical controllers evolved after rejected probes, so use the per-case
driver and manifest to reproduce a specific run. Run benchmarks sequentially;
decode/plot only after timed processes finish.

For write-heavy libcuckoo, `runs.csv` separates count calibrations, paired
confirmations and later native references: 105 rows in total (12, 84 and 9,
respectively). `summary.csv` reports ratios of
means, complete paired ranges and actual timed durations; the initial reserved
insert control lasts under one second and has a separate longer confirmation.
The initial hot-16 result and its fresh-seed recheck are also separate rows.
Do not pool those workloads or calibration/diagnostic timing with confirmations.
`raw-runs.jsonl.gz` retains every command, stdout and stderr; `experiments.jsonl`
contains per-case settings and binary hashes. `counters.csv`,
`address-samples.csv` and `profiles/` are separate whole-process diagnostics,
including setup/validation and selected-arena metadata. `runner-checks.json`
summarizes rejected inputs and real upstream smoke processes;
`raw-runner-checks.json.gz` preserves their full commands and output.

Run `python3 results/libcuckoo/write-heavy-20261119/scripts/summarize.py` from the
repository root to regenerate the derived CSVs. Other archived scripts preserve
the measured host's paths and frozen `build/libcuckoo-rmw/bench-final/` binaries;
they require fresh output directories and do not rebuild those binaries. Create
an empty `build/libcuckoo-write-heavy-20261119/` first. The measured order is
`run.py`, `extra.py`, `profile.py`, `check-runner.py`, `long-reserved.py`, then
`recheck-hot16.py`, sequentially after preparing the matching inputs. The longer
reserved control uses about 34 GiB RSS in the same 64 GiB/no-swap scope. Binary
perf data remains in the ignored build directory with hashes in `checks.json`.

For placement diagnosis, `runs.csv` separates `screen`, `diagnostic` and
`confirm` phases; `extent_policy` and `selected_node_mask` distinguish complete
single-node placement from the isolated interleave experiment. `node` is the
runtime target argument, not a claim that interleaved objects reside entirely
on that node. `experiments.jsonl` and compressed `raw-runs.jsonl.gz` retain exact
settings, commands, logs, validation and live interleave mapping snapshots.
The large micro ballast can be purged before the exit arena report; its live
three-page samples and, for interleave, live VMA page counts are separate checks.

`counters.csv`, `sample-positions.csv`, `sample-symbols.csv`, `sample-objects.csv`
and compressed `samples.csv.gz` retain diagnostic measurements; their throughput
is excluded from the confirmation means. `profiles.jsonl.gz` includes raw
counter output, rejected probes and process snapshots. Raw perf binaries remain
under ignored `build/placement-diagnosis/`; hashes are retained. The inactive
RCU trial is in `rejected-runs.jsonl.gz`. The interleave runtime patch is evidence
only, and does not change the production single-node runtime or add selection
parameters. `frozen-inputs.json` and `checks.json` record the unchanged inputs.

Run `python3 results/placement-diagnosis/20261119/scripts/summarize.py` and
`python3 results/placement-diagnosis/20261119/scripts/plot.py` from the repository
root to regenerate the derived summary/figure (Matplotlib is required for the
plot). Other scripts preserve the measured host's paths and frozen build inputs;
historical stage scripts include a failed inactive-RCU trial and its resume.
Use the benchmark guide to build the matching inputs before replaying individual
commands; do not blindly rerun all historical stage controllers.

For object-RMW/libcuckoo, `libcuckoo-runs.csv` labels every screen, confirmation
and control; `libcuckoo-raw.jsonl` retains stdout/stderr and commands, and
`experiments.jsonl` retains workload settings and binary hashes. Do not pool
short screens with confirmations. `selection/` and the rewrite-equivalence JSON
files compare the clean main baseline, initial extension and cached final
analysis. `validation/` holds state, placement, operation and sanitizer evidence.
`experimental-patches/` describes isolated library copies; the default builder
uses pristine upstream source.

This archive contains 501 uninstrumented libcuckoo rows: 303 confirmations and
controls, and 198 exploratory/smoke rows. The nine full XIndex and nine micro
regression rows are separate. `counters.csv`, `address-samples.csv` and
`profiles/` hold whole-process diagnostics, including compressed decoded
address samples and successful `mbind` ranges. They are excluded from throughput
means. `performance.png` / `.svg` plot the retained comparisons.

Use the current builder/runner from the benchmark guide for new libcuckoo runs.
The archive's `scripts/summarize.py` and `scripts/plot-results.py` regenerate
tables and the figure from retained CSVs when run from the repository root
(the plot requires Matplotlib). Other archived scripts preserve the measured
host's build layout and tool paths. `build-variants.sh` expects the plugin/runtime
in `build/libcuckoo-rmw/compiler/`, pristine upstream headers and the archived
`tool-env` at `build/jemalloc-comparison/tool-env`; it modifies build copies only.
`prepare-followup.py` expects the original binaries in `bench-final/` and the
variant binaries in `variant-*/`, interleaves implementations, then runs controls,
universal repetitions and `profile-locks.py`. Copy the latter script into
`build/libcuckoo-rmw/` before use. These drivers refuse existing result directories;
use a fresh build layout to reproduce an experiment. `experiments.jsonl` and
the raw command records specify the initial confirmations and all other runs.
The XIndex replay manifest preserves the dirty working tree at run start;
the root manifest explains its relation to the later implementation commits.

For allocator reproduction, build baseline `9d90964` and freeze matching
rewritten XIndex bitcode, libraries and binaries. The retained `compare.py`
expects `build/jemalloc-demand/baseline/` and `candidate/`; copy it into
`build/jemalloc-demand/` and run with `--rounds 4`. `lifecycle.py` uses the same
workspace for the allocation/free check. `final_pair.py` expects `final/`
binaries and writes a new `final-full/` directory, refusing an existing run.
Manifests give exact hashes/settings. Raw runtime-comparison logs/binaries remain
in ignored `build/jemalloc-demand/`, not in this archive. Historical drivers
expect their frozen artifacts; they do not rebuild historical revisions for you.

Microbenchmark evidence:

| Files | Protocol |
|---|---|
| `screen.csv`, `screen-cases.json` | 21 exploratory cases, one six-second pair each (42 rows) |
| `confirm.csv`, `confirm-cases.json` | Three 30-second pairs per corrected/epoch-store/padded variant (18 rows) |
| `fast.csv`, `fast-cases.json` | Three 20-second pairs per arithmetic variant (18 rows); regressing optimization removed |
| `profile.csv`, `profile-cases.json`, `counters.csv` | Ten 15-second hot-phase counter runs, 100% event running time |
| `hitm-samples.csv` | Five ten-second address-sampling runs, period 100,003 |
| `validation.csv`, `*-decisions.csv`, `inputs.sha256`, `tsan.log`, `btree-help.txt` | Write totals, selection, separate screen/final hashes, race check and supplied B-tree options |

Historical case runner/fast-index code: [9ed6717](https://github.com/minchurl/arbiter/tree/9ed6717).
Manual placement: [a2151db](https://github.com/minchurl/arbiter/tree/a2151db),
`ARBITER_BENCH_SELECTION=targeted` with the evidence-balanced policy.
Raw tuning logs/PEBS files remain in ignored `build/micro-tuning/`.
Sampling used `mem_load_l3_hit_retired.xsnp_fwd:upp` and
`mem_load_retired.l3_miss:upp`, `perf record -c 100003 -d -D -1`, controlled by
`--control fifo:CONTROL,ACK` plus `ARBITER_MICRO_PERF_CONTROL`/`ARBITER_MICRO_PERF_ACK`.
Match `perf script -F event,addr` to the executable's printed live object ranges.
The measured host used `/usr/lib/linux-hwe-6.8-tools-6.8.0-149/perf`.

## Historical slab-based XIndex

| Directory | How to interpret it |
|---|---|
| [A fulltrace-sweep-20261006](xindex/ycsb-a/fulltrace-sweep-20261006/) | 15/60/180-second cyclic replay. `final-stage-only-summary.csv` holds homogeneous four-pair 180-second results; mixed-stage rankings are screening, not one-pass measurements. |
| [A seed-only-replay-20261008](xindex/ycsb-a/seed-only-replay-20261008/) | One 180-second cyclic pair after deleting member expansion: 27.881/56.969 Mops/s. No final-state checksum. Old `hotset-*` artifact names remain. |
| [A one-pass-20261008](xindex/ycsb-a/one-pass-20261008/) | Four complete-trace pairs: 26.531/49.068 Mops/s, +85.03% mean paired. Distinct from the later ablation control. |
| [A site-ablation-20261020](xindex/ycsb-a/site-ablation-20261020/) | `comparison.csv`, `raw-046-pairs.csv`, `policy-screen.csv`: four pairs per policy, before later ABI/counter cleanup. |
| [A runtime-correctness-20261021](xindex/ycsb-a/runtime-correctness-20261021/) | Four site-68+71 pairs after ABI fixes, with per-operation validation counters. Logs, hashes, config, decisions, `runs.csv` and `summary.csv`. |
| [B fulltrace-sweep-20261008](xindex/ycsb-b/fulltrace-sweep-20261008/) | 100 inputs: 21 unique safe screens, 62 duplicates, 12 dynamic-size rejects, 4 empty, 1 build failure. Six screens had no runtime allocation, leaving 15 negative valid pairs. |
| [F one-pass-20261022](xindex/ycsb-f/one-pass-20261022/) | Counter-instrumented development/final rounds; different builds, do not pool. Includes short smoke and A-regression checks. |
| [F counterfree-20261022](xindex/ycsb-f/counterfree-20261022/) | Four full native/Local/CXL rounds after removing extra loop counters. Primary historical F evidence; logs, manifests, digests and operation totals retained. |
| [A/F demo-20261022](xindex/af-demo-20261022-1447/) | One pair each, counter-free: A 26.593/49.304, F 32.959/50.437 M tx/s. Logs/manifests/config and hashes retained. |

Archived B driver: [d78356a](https://github.com/minchurl/arbiter/tree/d78356a),
`scripts/run-xindex-ycsb-b-adaptive-sweep.sh`; frozen inputs remain under
[configs](../configs/hitm-seed/search-spaces/xindex-broad-100/).

Historical manifests/logs preserve original machine paths and settings, even
when those files or interfaces no longer exist. `artifacts.sha256` inventories
cover retained files; entries for removed narrative Markdown were pruned without
changing data checksums. Build/source hashes describe measured artifacts, not
necessarily current files. Original writeups and inventory versions remain at
[783706f](https://github.com/minchurl/arbiter/tree/783706f).

For new experiments, retain compact data plus a manifest and add one index row.
Update `docs/results.md` for a new conclusion. Keep generated run summaries in
the ignored build directory instead of checking in duplicate narrative reports.
