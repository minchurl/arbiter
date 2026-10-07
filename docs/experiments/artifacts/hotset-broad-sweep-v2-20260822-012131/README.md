# XIndex Broad Sweep v2 Raw Artifacts

This directory is a bounded, text-only copy of the top-level artifacts from:

```text
build/arbiter-bench/hotset-broad-sweep-v2-20260822-012131
```

The run started on 2026-08-22 at 01:21 KST from Git commit `7b7cf25`. It used
the full 100M/400M YCSB A traces, 31 foreground plus one background worker,
NUMA node 0 for CPUs/local memory, node 2 for CXL, `MemoryMax=64G`, and zero
swap.

The 38 entries in `observations.csv` are valid screen measurements: two native
anchors and one local/CXL pair for each of 18 statically unique candidates.
`phase1-summary.csv` is valid. `phase1-ranking.csv` is deliberately retained in
its malformed original form: the ranking writer omitted its output separator,
so confirmation aborted with `C_CONFIG: bad array subscript`. The nonempty
`promoted-confirm.txt` contains blank lines rather than candidate IDs. No
confirmation or final rows exist.

`controller.sh` and `plan.md` are the exact copies retained by the run, not the
subsequently fixed versions. `configs/` contains all 100 generated input
policies. Absolute paths in the CSVs refer to the original result directory.
Benchmark binaries, LLVM bitcode, build logs, full row directories, and the
26GB raw trace files are intentionally excluded.

See [the result ledger](../../hotset-broad-sweep-results.md) for the screen
summary, claim boundaries, and next-run priorities.
