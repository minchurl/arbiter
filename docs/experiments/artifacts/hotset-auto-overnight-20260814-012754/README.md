# XIndex Automatic Hot-Set Overnight Raw Artifacts

This directory is the durable, Git-tracked copy of the text artifacts produced
by the 2026-08-14 automatic-k1 overnight experiment. The original generated
directory was:

```text
/home/shin/arbiter/build/arbiter-bench/hotset-auto-overnight-20260814-012754/
```

The original 228 files were copied without modification and verified with
`diff -qr`. This README is the only file added to the archived copy.

## Start Here

- `manifest.txt`: frozen run shape, resource limits, topology, and row order.
- `runs.csv`: aggregate results and paths for all 22 rows.
- `throughput-samples.csv`: all 375 interval-throughput samples.
- `overnight-console.log`: top-level execution chronology.
- `main/`: seven paired Native, automatic-k1 Local, and automatic-k1 CXL rounds.
- `soak/`: the separate 60-minute automatic-k1 CXL stability run.
- `artifacts/auto-k1/`: retained compiler selection report and effective options.

Each row directory retains its benchmark log, `/usr/bin/time` log, summary,
throughput samples, input config, hot-set decision CSV, effective compiler
arguments, and binary hashes. The benchmark binaries and the large YCSB trace
files are deliberately not archived here.

## Resolving Recorded Paths

The CSV and console files intentionally preserve the absolute paths recorded on
the experiment machine. When a path begins with:

```text
/home/shin/arbiter/build/arbiter-bench/hotset-auto-overnight-20260814-012754/
```

strip that prefix and resolve the remaining suffix below this archive
directory. For example, a recorded path ending in
`main/round-01/row-01-native-native/logs/xindex_a_native_r1.log` maps to the
same relative path here.

## Analysis Contract

Use `../../hotset-auto-sweep-plan.md` for the frozen analysis method and record
the interpretation in `../../hotset-results.md`. `../../../../scripts/setup-benchmarks.sh`
documents fresh-machine dependencies and reconstruction, but neither setup nor
the benchmark needs to be executed to analyze this archive.

The aggregate sanity checks at archival time were:

- 22 of 22 rows had `status=ok`;
- `throughput-samples.csv` contained 375 data rows;
- the archive contained no binaries, symlinks, or detected credential-like
  strings.
