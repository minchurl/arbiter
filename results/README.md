# Retained evidence

Read [conclusions](../docs/results.md) first. This directory keeps original
measurements, validation extracts, configs and hashes; current commands are in
[the benchmark guide](../docs/benchmarks.md). Historical results are not reruns
of today's runtime. Directory names below link to the retained data directly.

## Latest allocator and benchmark comparisons

| Directory | Scope / principal files |
|---|---|
| [jemalloc-strict-20261119](xindex/ycsb-a/jemalloc-strict-20261119/) | Final 650-line runtime: one full A Local/CXL pair, no fresh controls. `runs.csv`, `manifest.json`, `validation.txt`, `checks.txt`, `code-size.csv`, `selected-sites.csv`. |
| [jemalloc-demand-20261118](xindex/ycsb-a/jemalloc-demand-20261118/) | Bounded vs initial 1,002-line demand runtime: four runs per allocator/placement, 16 total. `runs.csv`, `lifecycle.csv`, hashes/environment, code counts. Intermediate strict-only checks are not performance rows. |
| [jemalloc-20261117](xindex/ycsb-a/jemalloc-20261117/) | Custom slab vs bounded jemalloc: eight full A rows in `runs.csv`; five processes per cell in `arena-smoke.csv`. |
| [coherence-tuning/20261118](coherence-tuning/20261118/) | Corrected microbenchmark: layout/epoch improvements, counter evidence and negative screens; see file map below. |
| [published-rmw-20261118](allocation-policy/published-rmw-20261118/) | `decisions.csv`, `screen.csv`, `benchmark-runs.csv`, `xindex-runs.csv`, hashes. Automatic table selection and four A pairs per policy; original, not corrected, micro synchronization. |
| [btree-coherence/20261118](btree-coherence/20261118/) | Historical explicit-placement experiment: three native/Local/CXL runs per benchmark (`runs.csv`), separate supplied binaries (`supplied.csv`), reports/hashes. Original micro synchronization. |

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
