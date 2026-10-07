# XIndex Broad Sweep v1 Raw Artifacts

This directory is a bounded, text-only copy of the top-level artifacts from:

```text
build/arbiter-bench/hotset-broad-sweep-20260819-234706
```

The run started on 2026-08-19 at 23:47 KST from Git commit `7b7cf25`. It used
the full 100M/400M YCSB A traces, 31 foreground plus one background worker,
NUMA node 0 for CPUs/local memory, node 2 for CXL, `MemoryMax=64G`, and zero
swap.

Important caveat: `observations.csv`, the phase summaries, rankings, and the
manifest's `final_status=complete` are controller-corrupted. The v1 awk
row-count expression failed after every row, so the combined observation rows
were recorded as `row-accounting-` and no confirmation ran. Keep these files
as failure evidence; do not use their aggregate values as measurements. The
individual row outcomes can be reconstructed from `overnight-console.log`.

`controller.sh` and `plan.md` are the exact copies retained by the run, not the
subsequently fixed versions. `configs/` contains all 80 generated input
policies. Absolute paths in the CSVs refer to the original result directory.
Benchmark binaries, LLVM bitcode, full row directories, and the 26GB raw trace
files are intentionally excluded.

See [the result ledger](../../hotset-broad-sweep-results.md) for the recovered
screen results and interpretation.
