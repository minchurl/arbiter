# Protected XIndex Hot-Set Experiment

- Config: `/home/shin/arbiter/configs/hotset/xindex-cxl-arena-seed-size-heavy.config`
- Config SHA-256: `d0361eae4d18162490d78c83a90a1bad670d7c56af97e8454e2ae4e87d6fd149`
- Selected seeds: 8
- Scale: 100000000 load records, 400000000 transaction operations
- Workloads: `a`
- Repeats: 1
- Foreground threads: 31
- Background threads: 1
- Iterations: 1
- Duration seconds (0 means iteration mode): 180
- Throughput sample seconds: 30
- Alternate local/target order: 0
- First placement: local
- Cooldown seconds after each row: 2
- CPU node: 0
- Baseline memory node: 0
- Target memory node: 2
- Hot-set heap backend: arena
- Arena slab bytes: 2097152
- Arena reserve/capacity bytes: 25769803776
- Arena slot alignment: 64
- Arena strict/no-fallback: 1
- Protection: MemoryMax=64G, MemorySwapMax=0

| Workload | Config | Repeats | Avg time (s) | Avg throughput (op/s) | Avg max RSS (KiB) |
|---|---|---:|---:|---:|---:|
| a | hotset-seed-local | 1 | 180.004 | 27881100 | 31662236 |
| a | hotset-seed-target | 1 | 180.004 | 56969200 | 31662788 |

The local and target rows use the same rewritten hot-set binary and
the same heap backend. The arena is bound to node 0 for the
local row and node 2 for the target row.
