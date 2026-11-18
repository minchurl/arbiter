# Coherence tuning evidence — 2026-11-18

See [the analysis](../../../docs/results/coherence-tuning.md) for allocation
roles, methodology, comparisons, validation and reproduction.

- `screen.csv`: 42 exploratory rows, one six-second local/CXL pair per case.
- `confirm.csv`: 18 rows, three 30-second pairs per main variant.
- `fast.csv`: 18 rows, three 20-second pairs per arithmetic variant.
- `profile.csv` / `counters.csv`: ten 15-second hot-phase counter runs.
- `hitm-samples.csv`: address attribution from five ten-second sampling runs.
- `validation.csv`: actual reads, writes and summed entry versions for all 88 rows.
- `*-cases.json`: input cases for the reusable sweep runner.
- `*-decisions.csv`: compiler reports; only the table is selected in each build.
- `inputs.sha256`: supplied inputs, adapted sources, runtime/plugin and binary hashes.
- `tsan.log`: concurrency sanitizer check; `btree-help.txt`: supplied driver options.

Raw logs and build copies remain in `/home/shin/arbiter/build/micro-tuning/`.
Corrected workloads are distinguished from the original synchronization code.
Screening and final builds have separate hashes. CPU/memory placement is node 0
for workers and ordinary memory, with arena nodes 0 and 2 for local/CXL. All
sweep rows use 64 GiB systemd scopes and disable swapping.
