# Retained XIndex HITM-Risk Seed Configs

`candidates/` is a curated view of the 12 safe, runtime-active policies that retained the
strongest signals in the completed full-scale sweep and still produce the same
static seed fingerprint with the seed-only compiler. `raw-046.config` is the
retained search winner: it reaches the high-throughput plateau with less CXL
resident memory than the larger policies. The latest four-pair one-pass result
is 26.287M local versus 50.324M CXL op/s, or +91.53% mean paired improvement.

| Config | Three-pair delta | Runtime sites | Static seeds |
|---|---:|---|---:|
| `raw-046` | +109.37% | `68+71+74` | 8 |
| `raw-013` | +106.65% | `68+69+71` | 8 |
| `raw-043` | +104.98% | `21+37+68+69+71+74` | 12 |
| `raw-021` | +104.05% | `68+69+71+74` | 9 |
| `raw-039` | +100.34% | `68+71+74` | 6 |
| `raw-082` | +68.88% | `71` | 1 |
| `raw-081` | +65.21% | `71+74` | 2 |
| `raw-009` | +53.65% | `68+69` | 7 |
| `raw-030` | +53.31% | `21+68+69` | 8 |
| `raw-036` | +50.01% | `68` | 4 |
| `raw-003` | +49.00% | `68` | 3 |
| `raw-047` | +45.11% | `68+69` | 6 |

These values combine one 15-second screening pair and two 60-second
confirmation pairs. The five finalists also have homogeneous four-pair,
180-second results in [the YCSB-A result](../../docs/results/xindex-ycsb-a.md).
Config names are historical identifiers, not manually pinned site IDs; every
file leaves `ARBITER_HITM_SEED_SITE_IDS` empty.

The exact 100-input parameter space used by the broad YCSB-A and YCSB-B sweeps
is retained under `search-spaces/xindex-broad-100/`. Those inputs contain
historical no-op keys and are intended for search reproduction, not as
validated single-policy defaults. `candidates/` is the starting point for
current runs.

## Site 71 leaf-node ablation

`xindex-site71-leaf-ablation.config` isolates the collision B-tree leaf-block
allocation that accounted for 14.16 GiB (81.8%) of raw-046's CXL-assigned
memory. The original `candidates/raw-046.config` remains unchanged.

The ablation pins site 71 and sets the size weight to zero. This separates the
runtime effect of placing the leaf blocks from the size-heavy heuristic that
originally helped select them. It is a causal experiment, not a generalized
automatic policy: the current static features give sites 71 and 74 the same
feature vector, so lowering the size weight alone cannot distinguish the leaf
and internal-node allocation paths.

Run the same one-pass replay with the ablation config via:

```bash
ARBITER_HITM_SEED_CONFIG=configs/hitm-seed/xindex-site71-leaf-ablation.config \
HITM_SEED_BUILD_DIR=build/arbiter-bench/xindex-hitm-seed-site71 \
./scripts/run-xindex-hitm-seed-replay.sh
```

Compare that result with `candidates/raw-046.config`. If site 71 retains the
gain, the next step is to add a shared-write-sensitive feature that separates
leaf updates from mostly read-only container/internal-node access, rather than
using allocation size as a proxy.

## Four-way site ablation

The four-way driver compares `68 only`, `68+71`, `71 only`, and the original
`raw-046` under the same fixed-operation replay contract. The three explicit
ablation configs set the size weight to zero; `raw-046` remains unchanged.

```bash
./scripts/run-xindex-site-ablation.sh
```

The default is four Local/CXL pairs per policy. Use `--quick` for one pair per
policy or `--check` to validate the environment without starting a benchmark.
The driver writes per-policy evidence under `runs/` and creates top-level
`comparison.csv` and `comparison.md` files.

## General-policy candidates derived from sites 68 and 71

`policy-candidates/` contains automatic policies that select both of the
runtime-important XIndex sites without pinning their IDs.  They are hypotheses
to test on other benchmarks, not additional XIndex-specific winning claims.

| Viable config | Size weight | XIndex static seeds | Main hypothesis |
|---|---:|---|---|
| `evidence-balanced-size-tiebreaker` | 1 | `68,71,74,90,97,98,99,100` | count independent evidence; give worker reachability one extra point |
| `coherence-weighted-size-tiebreaker` | 1 | `68,71,74,90,97,98,99,100` | prioritize atomic RMW, cmpxchg, and lock-like updates |
| `sharing-weighted-size-tiebreaker` | 1 | `68,71,74,90,97,98,99,100` | prioritize stored pointers and worker-thread reachability |
| `balanced-size-tiebreaker` | 1 | `68,69,71,74,90,97,98,99,100` | retain size only as weak corroboration, instead of raw-046's dominant +6 |

All four leave `ARBITER_HITM_SEED_SITE_IDS` empty and leave the expected seed
count unset so that the same policy file can be compiled against another
benchmark.  The seed limit remains 12 to preserve the broad-sweep safety cap.
The XIndex fingerprints above were compiler-validated on 2026-10-20; they are
static selections, not a claim that every selected site is runtime-active.
The first three policies produce byte-identical rewritten XIndex bitcode and
executables.  The recommended `evidence-balanced-size-tiebreaker` executable
is also byte-identical to the raw-046 executable: both rewrite the same eight
static sites, while the new policy replaces raw-046's dominant size weight
with a weak +1 tie breaker.  On another benchmark their selections can differ.

There are two current-analysis limits to keep explicit:

1. Sites 71 and 74 expose the same static feature vector, so no existing
   weight/threshold combination can select 71 while rejecting 74.  A future
   shared-write or runtime-activity feature is required to separate them.
2. Setting the size weight to zero admits dynamic helper allocations with the
   same escape/sync/worker evidence as site 71.  An exploratory no-size policy
   crashed during XIndex training after rewriting those helpers, so the unsafe
   configs are not retained.  The viable policies use size only as a +1 tie
   breaker rather than as raw-046's dominant +6 signal.

For XIndex, compare one policy with raw-046 by passing it to the existing
one-pass replay driver, for example:

```bash
ARBITER_HITM_SEED_CONFIG=configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config \
HITM_SEED_BUILD_DIR=build/arbiter-bench/xindex-evidence-balanced-size-tiebreaker \
./scripts/run-xindex-hitm-seed-replay.sh
```
