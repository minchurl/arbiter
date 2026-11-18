# Strict jemalloc runtime: one final Local/CXL pair

[Implementation and results](../../../../docs/results/xindex-jemalloc-demand.md)

This directory contains exactly one full-trace measurement per placement,
following strict-only cleanup, allocation-failure diagnostics and C++ new
failure-contract fixes. Compare against the earlier four-run means under
`../jemalloc-demand-20261118/`; no fresh control runs were requested.
These are directional observations, not a repeated performance confirmation.

- `runs.csv`: both complete measurements, with correctness/placement fields.
- `manifest.json`: settings, executable/runtime/bitcode/plugin/source hashes.
- `topology.txt`: NUMA topology.
- `selected-sites.csv`, `rewrite.opt-args`: unchanged policy selection.
- `validation.txt`: full-run operation, state, arena and residency extracts.
- `checks.txt`: short failure-contract and injected-error check extracts.
- `code-size.csv`: main, intermediate stages and final runtime source lines.
- `final_pair.py`: fixed one-pair driver; copy it to
  `build/jemalloc-demand/final_pair.py`. It expects the final executable and
  bitcode/archive under `build/jemalloc-demand/final/` and refuses an existing
  `build/jemalloc-demand/final-full/` directory. It never automatically retries.

Raw logs/binaries remain under ignored `build/jemalloc-demand/`.
The intermediate 552-line cleanup was not benchmarked separately; this pair
cannot isolate the extra cost of the subsequent failure-handling changes.
