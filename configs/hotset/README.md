# Retained XIndex Hot-Set Configs

`candidates/` is a curated view of the 12 safe, runtime-active policies that retained the
strongest signals in the completed full-scale sweep and still produce the same
static seed fingerprint with the seed-only compiler. `raw-046.config` is the
recommended default: it reaches the high-throughput plateau with less CXL
resident memory than the larger policies.

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
180-second results in [the experiment report](../../docs/experiments/xindex-hotset.md).
Config names are historical identifiers, not manually pinned site IDs; every
file leaves `ARBITER_HITM_SEED_SITE_IDS` empty.

The older named configs in this directory and every generated sweep config in
`docs/experiments/artifacts/` are intentionally preserved. They are historical
inputs and may not satisfy the current seed-only expected-count checks without
review; `candidates/` is the validated starting point for current runs.
