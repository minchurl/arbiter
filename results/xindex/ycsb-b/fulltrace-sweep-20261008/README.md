# XIndex/YCSB-B 100-Config Sweep Result

This directory preserves the reportable outputs from the completed
`xindex-ycsb-b-sweep-20261008-085548` run. The source run was under the
git-ignored `build/arbiter-bench/` tree.

The experiment evaluated the 100 archived configuration inputs referenced by
`builds.csv`. It ran one full 400M-operation YCSB-B trace for each local/CXL
screening row. No candidate crossed the -15% promotion threshold, so the
confirmation and final stages were not entered.

Preserved files:

- `manifest.txt`: run settings and aggregate build counts;
- `builds.csv`: disposition of every one of the 100 input configurations;
- `selected-configs.csv`: 21 static-unique policies entering screening;
- `observations.csv`: all 50 process-level observations;
- `screen-summary.csv`: the 21 paired local/CXL screening outcomes;
- `native-summary.csv`: four native rows per workload;
- `git-status-at-start.txt`: source-tree state recorded at launch;
- `artifacts.sha256`: checksums for the retained files.

The controller snapshot was byte-for-byte identical to the checked-in runner,
and its console output was redundant with the retained CSVs, so neither copy
is kept here. Large per-row logs, compiled binaries, and build directories are
also excluded. Later focused and allocator-alignment experiments are out of
scope.

The CSVs preserve the absolute paths recorded during execution. Their old
`docs/experiments/artifacts/.../configs` prefix maps to the same parameter
combinations, translated to the current interface under
`configs/hitm-seed/search-spaces/xindex-broad-100/`. The
interpretation and claim boundary are documented in
[`docs/results/xindex-ycsb-b.md`](../../../../docs/results/xindex-ycsb-b.md).
Run `sha256sum -c artifacts.sha256` from this directory to verify the result.
