# XIndex Full-Trace Broad Hot-Set Sweep Results

> Historical result ledger: archived configs retain the member-expansion fields
> used by the original search. The active compiler is seed-only. The strongest
> seed-only finalist, `raw-046`, is reproduced by
> `configs/hitm-seed/xindex-cxl-arena-seed-size-heavy.config`.

This ledger preserves the evidence from two preliminary full-trace parameter
sweeps and the completed adaptive rerun. All runs used 100M load records, 400M
YCSB A transactions, 31 foreground workers, one background worker, CPU/local
NUMA node 0, CXL NUMA node 2, strict fixed-slot arenas, `MemoryMax=64G`, and no
swap.

The 2026-10-06 run completed screening, confirmation, and final phases after
the two earlier controllers exposed bugs during promotion. It is the primary
result. The August runs remain below because their failure modes motivated the
fixed-size filter and fail-closed controller checks.

## 2026-10-06: Completed Adaptive Rerun

The rerun used commit `fff0b32`, generated the same 100 deterministic configs,
and admitted 18 statically unique fixed-size candidates to screening. Thirteen
runtime-active candidates passed the broad screen and entered two additional
60-second pairs. Five distinct runtime fingerprints then entered four
additional 180-second pairs, for seven pairs per finalist across all phases.

The controller completed 131 fresh-process rows in 5 hours 39 minutes:

- final status `complete` and zero controller parse failures;
- 123 `ok` rows and eight screen rows with no runtime arena activity;
- zero OOM, timeout, swap, arena fallback, or placement-query error;
- maximum RSS 34,880,388 KiB (33.26 GiB);
- maximum CXL-resident arena 20,275,609,600 bytes (18.88 GiB);
- native anchors 27.9994M, 28.1054M, and 27.4271M op/s, with end versus start
  drift of -2.04%.

The controller's seven-pair summary mixes 15-, 60-, and 180-second rows. The
following table therefore reports only the homogeneous four-pair 180-second
final stage:

| Candidate | Runtime sites | Local | CXL | Mean paired delta | Delta stddev | CXL wins | CXL resident / peak RSS |
|---|---|---:|---:|---:|---:|---:|---:|
| `raw-043` | `21+37+68+69+71+74` | 27.656M | 57.345M | +107.68% | 9.05%p | 4/4 | 18.88 GiB / 59.81% |
| `raw-046` | `68+71+74` | 27.886M | 56.813M | +103.75% | 3.25%p | 4/4 | 17.31 GiB / 57.33% |
| `raw-021` | `68+69+71+74` | 28.484M | 57.103M | +100.47% | 0.79%p | 4/4 | 18.88 GiB / 59.81% |
| `raw-013` | `68+69+71` | 28.086M | 55.786M | +98.63% | 1.88%p | 4/4 | 18.88 GiB / 59.81% |
| `raw-082` | `71` | 28.801M | 44.896M | +55.86% | 11.63%p | 4/4 | 14.16 GiB / 48.12% |

All five finalists won all seven local/CXL pairs when screen and confirmation
were included. Within each 180-second process, 30-second throughput intervals
were generally stable; most coefficients of variation were below 0.5%.
`raw-082` had one lower CXL process, but that process remained steadily lower
for the full three minutes rather than showing a transient collapse.

The top policies converge on two important runtime allocations:

- site 68: a 96-byte group/hash object in `xindex_group_impl.h`;
- site 71: a 520-byte leaf allocation in `xindex_buffer_impl.h`.

Site 68 alone retained a roughly +50% signal through three pairs, site 71 alone
reached +55.86% in the 180-second final stage, and `raw-046` combined sites 68
and 71 for +103.75%. Site 74 allocated only 143 objects and contributed
negligible resident volume. Additional site 69 placement increased resident
memory without improving the absolute CXL throughput beyond the 68+71 policy.

## 2026-10-08: Seed-Only Cleanup Replay

After use-based member expansion was removed, the seed-only implementation was
rebuilt and replayed with the `raw-046`-equivalent automatic policy. Its eight
static seeds and active runtime fingerprint `68+71+74` exactly matched the
archived finalist.

One 180-second full-trace local/CXL pair produced 27.8811M and 56.9692M op/s,
respectively: **+104.33%** for CXL placement. Relative to the earlier four-pair
means, local differed by -0.02%, CXL by +0.28%, and the paired delta by +0.58
percentage points. Both processes used 17.31GiB of arena-resident memory on
the requested node and completed with zero fallback, swap, placement-query
error, or OOM. This is a regression confirmation rather than an additional
statistical claim; the earlier four-pair result remains the confidence basis.

The local finalist means remained close to the 27.844M native-anchor mean, so
the slab/rewrite path did not create a large local overhead. This strengthens
the placement signal but does not prove its mechanism. HITM/C2C and latency
counters were not collected, and the benchmark did not validate `get`/`put`
return values or a final data checksum. Correctness instrumentation and focused
long runs of site 68, site 71, and their automatic combination should precede
another broad parameter search.

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

## Interpretation and Next Validation

The completed adaptive run confirms that the August signals were not isolated
15-second outcomes. The next decision is no longer which static threshold to
search. Multiple policies collapse to the same runtime fingerprints and the
top absolute CXL throughput plateaus near 56--58M op/s. The highest-value work
is now validation:

1. add `get`/`put` success counts and a deterministic final checksum;
2. compare automatic site-68, site-71, and combined policies in five or more
   10-minute pairs;
3. isolate benchmark CPUs from OS/editor activity;
4. collect HITM/C2C, memory-bandwidth, and p99 latency counters;
5. require correctness agreement and a confidence-interval floor before
   exploring new thresholds or probabilistic placement.

Manual site pins may be useful for mechanism ablation, but the primary
performance candidates remain the automatic configs. `raw-082` is the clean
single-site result and `raw-046` is the efficient aggressive result.

## Retained Evidence

- The failed V1 and incomplete V2 raw artifacts were removed from the active
  tree and remain recoverable from Git history.
- [Completed adaptive rerun aggregates](../../results/xindex/ycsb-a/fulltrace-sweep-20261006/README.md)
- [Seed-only `raw-046` replay evidence](../../results/xindex/ycsb-a/seed-only-replay-20261008/README.md)
- [Frozen 100-config search inputs](../../configs/hitm-seed/search-spaces/xindex-broad-100/README.md)
- [Historical plan and commands](hotset-broad-sweep-plan.md)
