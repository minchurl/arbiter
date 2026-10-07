# Protected XIndex Hot-Set Experiment

- Config: `/home/shin/arbiter/configs/hotset/xindex-cxl-arena-auto-k1-s13.config`
- Config SHA-256: `a361633e9693172821a0aae2b79afe74ce80e893433caefc29355fa7f2eee529`
- Selected sites: 1 seeds, 0 members
- Scale: 20000000 load records, 80000000 transaction operations
- Workloads: `a`
- Repeats: 1
- Foreground threads: 31
- Background threads: 1
- Iterations: 3
- Duration seconds (0 means iteration mode): 900
- Throughput sample seconds: 60
- Alternate local/target order: 0
- First placement: local
- Cooldown seconds after each row: 5
- CPU node: 0
- Baseline memory node: 0
- Target memory node: 2
- Hot-set heap backend: arena
- Arena slab bytes: 2097152
- Arena reserve/capacity bytes: 4294967296
- Arena slot alignment: 64
- Arena strict/no-fallback: 1
- Protection: MemoryMax=40G, MemorySwapMax=0

| Workload | Config | Repeats | Avg time (s) | Avg throughput (op/s) | Avg max RSS (KiB) |
|---|---|---:|---:|---:|---:|
| a | hotset-use-local | 1 | 900.064 | 13210400 | 12577236 |

The local and target rows use the same rewritten hot-set binary and
the same heap backend. The arena is bound to node 0 for the
local row and node 2 for the target row.
