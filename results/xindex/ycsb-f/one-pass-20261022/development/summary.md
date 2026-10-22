# Protected XIndex HITM-Risk Seed Experiment

- Config: `/home/shin/arbiter/configs/hitm-seed/policy-candidates/evidence-balanced-size-tiebreaker.config`
- Config SHA-256: `e60729fc877532b6fdbeb0ed3337be4fd8d29fc72de68dab8941ba76acf8f9e3`
- Selected seeds: 8
- Scale: 100000000 load records, 400000000 transaction operations
- Workloads: `f`
- Repeats: 1
- Foreground threads: 31
- Background threads: 1
- Execution contract: fixed-operation, 1 complete trace pass(es), no duration cutoff
- Iterations: 1
- Duration seconds (0 means iteration mode): 0
- Throughput sample seconds: 0
- Alternate local/target order: 1
- First placement: local
- Cooldown seconds after each row: 2
- CPU node: 0
- Baseline memory node: 0
- Target memory node: 2
- HITM-risk seed heap backend: arena
- Arena slab bytes: 2097152
- Arena reserve/capacity bytes: 25769803776
- Arena slot alignment: 64
- Arena strict/no-fallback: 1
- Protection: MemoryMax=64G, MemorySwapMax=0

| Workload | Config | Repeats | Avg time (s) | Avg throughput (op/s) | Avg max RSS (KiB) |
|---|---|---:|---:|---:|---:|
| f | native | 1 | 12.5655 | 31833200 | 32641624 |
| f | hitm-seed-local | 1 | 11.7318 | 34095500 | 31662996 |
| f | hitm-seed-target | 1 | 8.11663 | 49281500 | 31663076 |

The local and target rows use the same rewritten HITM-risk seed binary and
the same heap backend. The arena is bound to node 0 for the
local row and node 2 for the target row.
