# XIndex/YCSB-B 100-config sweep artifact

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
- `summary.md`: controller-generated final summary;
- `sweep-console.log`: controller output;
- `controller.sh`: exact generated controller used by the run;
- `git-status-at-start.txt`: source-tree state recorded at launch.

Large per-row logs, compiled binaries, and build directories are deliberately
not archived. Later focused and allocator-alignment experiments are also out
of scope. The interpretation and claim boundary are documented in
`../../xindex-ycsb-b-adaptive-sweep.md`.
