# XIndex Full-Trace Broad Hot-Set Sweep Results

This ledger preserves the useful evidence from two preliminary full-trace
parameter sweeps. Both runs used 100M load records, 400M YCSB A transactions,
31 foreground workers, one background worker, CPU/local NUMA node 0, CXL NUMA
node 2, strict fixed-slot arenas, `MemoryMax=64G`, and no swap.

Neither run reached its planned repeated confirmation phase. The percentages
below are therefore **15-second, one-pair screening signals**, not stable
performance claims. The strongest validated long-run result remains the
20M/80M automatic-k1 experiment described in [Hot-Set Placement Experiment
Results](hotset-results.md).

## 2026-08-19: Broad Sweep v1

The first controller generated 80 raw policies and retained 29 statically
unique candidates. Thirty-six builds failed, largely because some generated
configs had invalid affinity values or exceeded policy budgets.

The benchmark rows themselves completed, but an ambiguous awk expression used
to count `runs.csv` rows was parsed as output redirection on this machine. Every
observation became `row-accounting-`, the ranking was empty, and the controller
incorrectly wrote `final_status=complete`. The row directories and console log
show what actually happened:

- five policies had no runtime arena activity;
- 18 policies exited with `SIGSEGV` (`139`);
- six policies completed safely;
- every crash included a selected dynamic-size allocation site, most often
  site 72. The fixed-slot arena accepted the first observed size, then strict
  mode returned null when that site's size changed; XIndex later dereferenced
  the null result. This was not an OOM event.

The six safe rows produced positive short-screen CXL/local signals:

| Runtime sites | Representative candidate | CXL over local | CXL-resident arena |
|---|---|---:|---:|
| `68` | `raw-003` | +47.34% | 3.15 GiB |
| `68` | `raw-004` | +74.36% | 3.15 GiB |
| `68+69` | `raw-009` | +46.21% | 4.72 GiB |
| `68` | `raw-033` | +37.44% | 3.15 GiB |
| `71` | `raw-042` | +56.35% | 14.16 GiB |
| `68+69+71` | `raw-055` | +106.15% | 18.88 GiB |

These values were reconstructed from each row's retained `runs.csv` and arena
report because v1's combined `observations.csv` is invalid.

## 2026-08-22: Broad Sweep v2

V2 disabled dynamic-size selection and independently rejected any compiler
report that still selected a nonconstant allocation size. Of 100 generated
configs, one failed to build, 56 were rejected as unsafe nonconstant-size
policies, 21 duplicated an earlier static site set, and four selected no sites.
Eighteen statically unique candidates entered the screen.

All 38 planned processes produced measurements: two native anchors and one
local/CXL pair for each candidate. Thirty rows were `ok`; the other eight were
the four candidate pairs with no runtime arena activity. No process crash,
swap, arena fallback, placement-query error, timeout, or OOM was observed. Peak
RSS was 34,880,124 KiB (33.26 GiB), below the 64G cgroup limit; the largest
resident arena was 20,275,609,600 bytes (18.88 GiB).

The two native anchors measured 26.7045M and 27.2819M op/s, a +2.16% drift over
the screen. Every active candidate showed a positive CXL/local signal between
+40.24% and +103.53%. Representative runtime footprints were:

| Runtime sites | Candidate(s) | CXL over local | CXL-resident arena / peak RSS |
|---|---|---:|---:|
| `68` | `raw-003`, `raw-004`, `raw-036` | +40.24% to +58.71% | 3.15 GiB / 9.87% |
| `68+69` | `raw-009`, `raw-047` | +44.84% to +45.32% | 4.72 GiB / 14.19% |
| `71` | `raw-014`, `raw-082` | +58.48% to +78.17% | 14.16 GiB / 48.12% |
| `68+71+74` | `raw-039`, `raw-046` | +97.22% to +97.51% | 17.31 GiB / 57.32% |
| `68+69+71` | `raw-013` | +101.92% | 18.88 GiB / 59.81% |
| `68+69+71+74` | `raw-021` | +103.53% | 18.88 GiB / 59.81% |

The compiler's static selected-site set was often larger than the set observed
at runtime. For example, full-trace automatic-k1 and k2 selected sites 97/99
statically but allocated no arena object; k3 and k6 both reduced to runtime
site 68. Runtime fingerprints and resident bytes, rather than static `k`, must
therefore drive comparison and promotion.

After the middle native anchor, the phase-one ranking writer omitted its CSV
output separator. It emitted lines such as
`1raw-021103.52968+69+71+74`; promotion then read an empty candidate field and
failed with `C_CONFIG: bad array subscript`. Confirmation, final measurements,
and the ending native anchor did not run. The driver now emits comma-separated
rankings, tests the exact formatter in `--check`, and validates every promoted
candidate before array lookup.

## Interpretation and Next Run

The broad screens establish three things only:

1. Full-trace fixed-size placement is safe under the tested 64G/zero-swap
   envelope.
2. Sites 68, 69, and 71 are active at full scale, while the partial-trace
   sites 97 and 99 are not active in this workload shape.
3. Moving roughly 10%, 14%, 48%, or 60% of peak RSS is experimentally
   reachable, and each tier had a large positive 15-second signal worth
   confirming.

They do not establish a +40% to +103% durable gain or prove that reduced HITM
caused the signal. There is only one pair per policy, rows are short, the host's
background tasks were not isolated from node 0, and no HITM/C2C or latency
counters were collected.

The next run should first execute the driver's non-mutating `--check`, then
repeat representative runtime footprints rather than every static duplicate.
Site 71 is the priority because its 48% resident/RSS ratio lies inside the
previously proposed 30--55% migration band. At minimum, confirm `68`, `68+69`,
`71`, and one aggressive roughly-60% policy with three 60-second pairs before
promoting finalists to seven 180-second pairs or longer. Keep benchmark CPUs on
node 0 and isolate OS/editor/Codex activity to node 1 where operationally
possible. A later mechanism run should add HITM/C2C and p99 latency collection.

## Archived Evidence

- [V1 top-level artifacts](artifacts/hotset-broad-sweep-20260819-234706/README.md)
- [V2 top-level artifacts](artifacts/hotset-broad-sweep-v2-20260822-012131/README.md)
- [Next-run plan and commands](hotset-broad-sweep-plan.md)
