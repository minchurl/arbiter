# Protected XIndex HITM-Risk Seed Experiment

- Config: `/home/shin/arbiter/configs/hitm-seed/xindex-site68-71-ablation.config`
- Config SHA-256: `3011d6be7ee3c322126d2ab7128a6423a088d139725465ddb09063fdb734e72b`
- Selected seeds: 2
- Scale: 100000000 load records, 400000000 transaction operations
- Workloads: `a`
- Repeats: 4
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
| a | hitm-seed-local | 4 | 14.455 | 27685450 | 31663074 |
| a | hitm-seed-target | 4 | 8.0142125 | 49917200 | 31663000 |

The local and target rows use the same rewritten HITM-risk seed binary and
the same heap backend. The arena is bound to node 0 for the
local row and node 2 for the target row.
