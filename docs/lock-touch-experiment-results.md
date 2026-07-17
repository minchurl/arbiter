# Lock-Touch Experiment Results

This note summarizes the initial XIndex results for the lock-touch page
migration experiment. The implementation and runtime controls are described in
`docs/lock-touch-page-migration.md`.

## Current Implementation

The experiment instruments lock-like synchronization targets and calls:

```c
void arbiter_lock_touch(void *addr, uint32_t site_id);
```

Runtime modes:

```text
ARBITER_LOCK_TOUCH_MODE=auto|off|touch|migrate
ARBITER_LOCK_TOUCH_SAMPLE_PERIOD=<n>
ARBITER_LOCK_TOUCH_THRESHOLD=<n>
ARBITER_LOCK_TOUCH_STATS=0|1
ARBITER_TARGET_NODE=<node>
```

The runtime samples lock touches, tracks touched virtual pages in a lock-touch
page table, and optionally attempts one `move_pages(..., MPOL_MF_MOVE)` per
page after the sampled-touch threshold. `ARBITER_LOCK_TOUCH_STATS=1` prints
one process-exit stats line, which the experiment sweep records in CSV form.

## Short Parameter Sweep

Result directory:

```text
build/arbiter-bench/lock-touch-sweep-1m4m-20260717-040322
```

Workload:

```text
1M load / 4M tx
```

This first sweep used short runs, so it is useful mostly for sanity-checking
correctness, measuring rough overhead, and pruning obviously bad settings.

| Config | Mode | Sample | Threshold | Time (s) | Throughput | vs Native |
|---|---|---:|---:|---:|---:|---:|
| native | native | - | - | 0.496707 | 4.02652e+07 | 1.000x |
| lock-touch-off | off | - | - | 0.521061 | 3.83832e+07 | 0.953x |
| s256_t16 | touch | 256 | 16 | 0.542023 | 3.68988e+07 | 0.916x |
| s256_t16 | migrate | 256 | 16 | 0.556977 | 3.59081e+07 | 0.892x |
| s1024_t64 | touch | 1024 | 64 | 0.537247 | 3.72268e+07 | 0.925x |
| s1024_t64 | migrate | 1024 | 64 | 0.541229 | 3.69529e+07 | 0.918x |
| s4096_t256 | touch | 4096 | 256 | 0.535962 | 3.73161e+07 | 0.927x |
| s4096_t256 | migrate | 4096 | 256 | 0.537470 | 3.72114e+07 | 0.924x |

Observations:

- Even `ARBITER_LOCK_TOUCH_MODE=off` loses about 4.7% versus native in this
  short run, which points to non-trivial instrumentation/call overhead.
- Touch-only settings lose roughly 7.3% to 8.8% versus native.
- Migration does not beat native in the short sweep.
- More conservative sampling generally looks better than aggressive sampling.

## Longer Three-Setting Sweep With Stats

Result directory:

```text
build/arbiter-bench/lock-touch-sweep-1m4m-long-20260717-042028
```

Workload:

```text
1M load / 4M tx
XINDEX_ITERATION=800
XINDEX_FG=16
```

This run reduced the parameter space to three settings and completed in about
9.65 minutes wall-clock across all runs. It used `ARBITER_LOCK_TOUCH_STATS=1`
for the instrumented variants.

| Config | Mode | Sample | Threshold | Time (s) | Throughput | vs Native | Attempts | Successes | Pages |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| native | native | - | - | 62.2071 | 5.14411e+07 | 1.000x | - | - | - |
| lock-touch-off | off | - | - | 68.2791 | 4.68665e+07 | 0.911x | 0 | 0 | 0 |
| s256_t16 | touch | 256 | 16 | 69.5636 | 4.60011e+07 | 0.894x | 0 | 0 | 194780 |
| s256_t16 | migrate | 256 | 16 | 77.2120 | 4.14444e+07 | 0.806x | 99098 | 99098 | 194437 |
| s1024_t64 | touch | 1024 | 64 | 69.5211 | 4.60292e+07 | 0.895x | 0 | 0 | 141320 |
| s1024_t64 | migrate | 1024 | 64 | 69.2076 | 4.62377e+07 | 0.899x | 2380 | 2380 | 141644 |
| s4096_t256 | touch | 4096 | 256 | 69.4076 | 4.61044e+07 | 0.896x | 0 | 0 | 104506 |
| s4096_t256 | migrate | 4096 | 256 | 69.6896 | 4.59179e+07 | 0.893x | 89 | 89 | 104631 |

Selected stats from `runs.csv`:

| Config | Mode | Hook Calls | Sampled Calls | Max Sampled Touches |
|---|---|---:|---:|---:|
| lock-touch-off | off | 5606554026 | 0 | 0 |
| s256_t16 | touch | 5584602728 | 21814864 | 12499053 |
| s256_t16 | migrate | 5559765393 | 21717842 | 12501644 |
| s1024_t64 | touch | 5586534029 | 5455609 | 3124082 |
| s1024_t64 | migrate | 5581765546 | 5450952 | 3124234 |
| s4096_t256 | touch | 5591743858 | 1365181 | 780185 |
| s4096_t256 | migrate | 5590880577 | 1364969 | 781853 |

Observations:

- The hook is extremely hot: roughly 5.6 billion calls per run.
- `lock-touch-off` is still about 8.9% slower than native, so the direct
  instrumentation and call path are already a major part of the cost.
- Aggressive migration (`s256_t16`) is clearly too expensive. It moved about
  99k pages and dropped to 0.806x native throughput.
- The middle setting (`s1024_t64`) is the only case where migrate slightly
  beats touch-only, but it is still below native and below lock-touch-off.
- The conservative setting (`s4096_t256`) attempts only 89 migrations; that is
  probably too little policy action to overcome the persistent hook cost.

## Interpretation

The current data does not show a native-beating migration configuration for
this XIndex setup. The most likely reason is that the experiment pays a steady
per-synchronization cost for the hook, while page migration benefit is one-shot
and workload-dependent.

The page migration path can still be useful if these conditions hold:

- lock-bearing pages start on a remote NUMA node,
- the threads that mostly use those pages are concentrated on the target node,
- the pages remain stable after migration,
- remote lock/page traffic is expensive enough to amortize `move_pages`, and
- the runtime stops paying most lock-touch overhead after placement has settled.

The current natural placement run may not satisfy those conditions strongly.
The OS/default NUMA policy may already be good enough, or the target-node policy
may be moving pages that do not actually belong with the active worker set.

## Would A 10-Hour Run Help?

A longer run can help answer whether one-shot migration cost amortizes over
time, but it will not remove the continuing hook cost. Since `arbiter_lock_touch`
is still called billions of times, a 10-hour run without a cutoff is likely to
preserve much of the overhead seen above.

A better long-run design would compare:

```text
native
lock-touch-off
s1024_t64_touch
s1024_t64_migrate
```

with repeated runs and deliberate NUMA placement, rather than spending the
entire budget on one unreplicated run.

## Recommended Next Experiments

1. Add an active-window cutoff.

   Example control:

   ```text
   ARBITER_LOCK_TOUCH_ACTIVE_MS=<milliseconds>
   ```

   The runtime would sample and migrate only during the initial active window,
   then make `arbiter_lock_touch` return through a very cheap disabled fast
   path. Suggested first values: 30000, 60000, and 120000.

2. Force a more adversarial NUMA setup.

   Use `numactl` or the existing runner controls to create a clear mismatch
   between initial memory placement and worker placement. This should make it
   easier to see whether migration can recover remote-access loss.

3. Filter sites using the report.

   The v1 pass instruments every recognized lock/atomic site. The stats show
   that this is expensive. A follow-up pass option could instrument only an
   allowlist of hot/relevant site IDs from the report CSV.

4. Repeat the best candidate.

   Current best migration candidate:

   ```text
   ARBITER_LOCK_TOUCH_SAMPLE_PERIOD=1024
   ARBITER_LOCK_TOUCH_THRESHOLD=64
   ARBITER_LOCK_TOUCH_MODE=migrate
   ```

   This setting produced the only migrate-over-touch result in the longer
   sweep, but the margin is small and needs repeated runs.

## Current Conclusion

Lock-touch migration is implemented and measurable, but the first XIndex
results show that always-on instrumentation dominates the current benefit. The
next meaningful change is to make lock-touch a temporary placement phase rather
than a steady-state hook.
