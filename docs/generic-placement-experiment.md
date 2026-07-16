# Generic Placement Experiment

This experiment compares the current generic shared-mutable placement pass
against native execution and the all-select Arbiter baseline.

## Configurations

GUPS:

```text
native
all-local
all-remote
```

XIndex/YCSB:

```text
native
all-local
generic-local
all-remote
generic-remote
```

The `local` runs unset `ARBITER_TARGET_NODE` and isolate compiler/runtime
overhead. The `remote` runs set `ARBITER_TARGET_NODE`, defaulting to node `1`.
The runner binds benchmark CPU and baseline memory to node `0` by default.

## Estimate

On the current 48-thread, 2-node machine, previous XIndex/YCSB-A runs took
about 5-6 minutes per configuration. A full overnight run with workloads A and
B, five XIndex configurations, and three repeats is expected to take roughly
4-6 hours. GUPS is much shorter and is mainly a sanity/control workload for
the mmap placement path.

Default run count:

```text
GUPS:        3 configs x 3 repeats = 9 runs
XIndex/YCSB: 5 configs x 2 workloads x 3 repeats = 30 runs
Total:      39 runs
```

## Run

Start the full experiment from the repository root in tmux:

```sh
tmux new-session -d -s arbiter-generic-exp -c "$(pwd)" \
  'mkdir -p build/arbiter-bench/generic-placement-experiment && REPEATS=3 ./scripts/run-generic-placement-experiment.sh 2>&1 | tee build/arbiter-bench/generic-placement-experiment/driver.log'
tmux attach -t arbiter-generic-exp
```

Detach from the attached view with `Ctrl-b d`. Reattach with:

```sh
tmux attach -t arbiter-generic-exp
```

For a shorter pilot:

```sh
REPEATS=1 XINDEX_WORKLOADS=a ./scripts/run-generic-placement-experiment.sh
```

## Results

The runner writes:

```text
build/arbiter-bench/generic-placement-experiment/runs.csv
build/arbiter-bench/generic-placement-experiment/summary.csv
build/arbiter-bench/generic-placement-experiment/summary.md
build/arbiter-bench/generic-placement-experiment/driver.log
build/arbiter-bench/generic-placement-experiment/logs/
```

Use `summary.md` for a quick read, `summary.csv` for tables/plots, and the logs
for debugging failed or anomalous runs.
