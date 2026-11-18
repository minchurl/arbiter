# Demand-mapped jemalloc runtime comparison

See [the report](../../../../docs/results/xindex-jemalloc-demand.md) for the
implementation, runtime line reduction, full-trace results and limitations.
The full benchmark rows describe the 1,002-line pool-removal runtime before
the later strict-only cleanup. They are not measurements of the final runtime.
`strict-code-size.csv` and `strict-checks.txt` describe that later cleanup;
its checks are short correctness tests only. The final failure-contract version
has a separate [single Local/CXL pair](../jemalloc-strict-20261119/README.md).

Baseline: `9d9096491b883ecf11a57b96159a9aed1f7506a3` (bounded jemalloc).

- `runs.csv`: all 16 full-trace measurements, four per allocator/placement.
- `manifest.json`: workload settings and frozen source/bitcode/binary hashes.
- `environment.json`, `topology.txt`: host configuration.
- `validation.txt`: per-run operation, state and allocation/residency reports.
- `code-size.csv`: physical source lines, including comments and blanks.
- `checks.txt`: runtime, runner, micro and lifecycle validation summary.
- `lifecycle.csv`, `lifecycle.py`: supplemental allocation/free/reuse timings
  and driver; copy the driver under `build/jemalloc-demand/` before running.
- `compare.py`: comparison driver; copy to `build/jemalloc-demand/compare.py`
  before running with `--rounds 4`. See the report for required artifacts.

Raw logs and binaries remain under ignored `build/jemalloc-demand/`.
All rows are retained, including the low candidate CXL result. Process wall
seconds include input parsing and validation; `tx_per_s` is the benchmark's
post-construction transaction throughput. `timed_s` is derived as operations
/ reported throughput and therefore inherits its rounding.
