# Selection configs

Choose by purpose; historical rankings are in [results](../../docs/results.md).
All paths below are relative to this directory.

| Config / directory | Use |
|---|---|
| `candidates/raw-046.config` | Default XIndex replay; historical broad-sweep winner with a smaller footprint than larger finalists |
| `policy-candidates/evidence-balanced-size-tiebreaker.config` | A/F convenience runners; same XIndex sites with size reduced from +6 to +1 |
| `policy-candidates/published-rmw-size-tiebreaker.config` | B-tree/micro/libcuckoo default; selects the micro table and libcuckoo locks, excludes ballast, preserves measured XIndex selection |
| Other `policy-candidates/` | Automatic hypotheses for sensitivity/generalization, not additional proven winners |
| `xindex-site68-buffer-ablation.config`, `xindex-site71-leaf-ablation.config`, `xindex-site68-71-ablation.config` | Explicitly pinned causal ablations, not general policies |
| `candidates/` | 12 historically measured policies: 003, 009, 013, 021, 030, 036, 039, 043, 046, 047, 081, 082 (all `raw-*.config`) |
| `search-spaces/xindex-broad-100/` | Frozen 100-input search space, not 100 validated policies |

Automatic policies leave `ARBITER_HITM_SEED_SITE_IDS` empty. The retained
raw-046/evidence-balanced/published-RMW XIndex selection is
`68,71,74,90,97,98,99,100`; only `68,71,74` allocate in full A. IDs are specific
to the measured build. Other benchmarks can select different sites or none.

```sh
ARBITER_HITM_SEED_CONFIG=configs/hitm-seed/policy-candidates/published-rmw-size-tiebreaker.config \
  ./scripts/build-xindex-llvm.sh
./scripts/run-xindex-site-ablation.sh --check
```

The ablation runner compares 68, 71, 68+71 and raw-046; default four pairs per
policy, `--quick` one pair. General replay commands are in the
[benchmark guide](../../docs/benchmarks.md#xindex-a-and-f).

## Parameters

Each `ARBITER_HITM_WEIGHT_*` signal contributes at most once per allocation.

| Suffix | Evidence |
|---|---|
| `ESCAPE_RETURN`, `ESCAPE_STORE`, `ESCAPE_CALL` | Derived pointer returned, stored or passed to a non-ignored call |
| `SYNC_ATOMIC`, `SYNC_STORE`, `SYNC_INLINE_ASM`, `SYNC_FILE` | RMW/CAS, atomic/volatile store, lock-like assembly, or source-file mutation |
| `PUBLISHED_RMW` | Allocation-linked RMW/CAS through a global, object field or call; default weight 0 |
| `WORKER_ENTRY`, `WORKER_REACHABLE` | In/reachable from a recognized pthread or std::thread entry |
| `SIZE` | Crosses `ARBITER_HITM_LARGE_ALLOCATION_THRESHOLD` |

`ARBITER_HITM_REQUIRE_ESCAPE`, `ARBITER_HITM_REQUIRE_SYNC` and
`ARBITER_HITM_MIN_SCORE` gate automatic candidates; `ARBITER_HITM_SEED_LIMIT`
caps the deterministic ranking. `ARBITER_HITM_INCLUDE_DYNAMIC_SIZE` awards the size feature to
non-constant requests; disabling it does not reject those allocations. `ARBITER_HITM_SEED_DYNAMIC_SIZE_ESTIMATE` provides their
static accounting size; `ARBITER_HITM_SEED_MAX_ESTIMATED_BYTES` aborts compilation
if the selected sum exceeds a nonzero budget. These are not runtime byte limits.

Current jemalloc supports mixed sizes. Historical XIndex candidates still
disable the dynamic-size score because of their validation history. An earlier zero-size-
weight policy admitted helper allocations and crashed during training; it has
not been revalidated on this runtime. Existing features also cannot distinguish
sites 71 and 74, which share a feature vector. Static RMW evidence does not
establish multiple runtime writers or predict a placement gain by itself.

The frozen broad search contains duplicates, empty selections and candidates
rejected by the old fixed-slot runtime. Legacy expansion/member keys remain
historical no-ops: the build wrapper forwards only its explicit seed-option
allowlist. Check `configs.sha256` from that directory to verify the inputs.
Use the source configs and compiler decision CSVs for exact weights; avoid
copying evolving rankings into additional READMEs.

Object-path and std::thread support reuse the existing weights and unchanged
published-RMW config. Analysis scope and unresolved-path limits are documented
in [Selection](../../docs/overview.md#selection).
