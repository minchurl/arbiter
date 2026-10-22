# XIndex HITM-Risk Seed Result Interpretation

- Result directory: `/home/shin/arbiter/build/arbiter-bench/xindex-ycsb-f-20261022-135824`
- Static seeds selected by the compiler: 8
- Execution contract: fixed-operation, 1 complete trace pass(es), no duration cutoff
- Comparison: the same rewritten binary and arena allocator; only the arena NUMA node changes

## Selection Policy

| Parameter | Value | Meaning |
|---|---:|---|
| Minimum score | 5 | selection threshold |
| Seed limit | 12 | maximum selected groups/sites after ranking |
| Explicit site IDs | `empty` | empty means score-based automatic selection |
| Size weight | 1 | score weight for allocation size |
| Require escape / synchronization | 1 / 1 | both gates must pass |
| Large-allocation threshold | 128B | size signal threshold |
| Include dynamic-size sites | 0 | disabled in the retained policy |

## Throughput

For YCSB-F, op/s counts logical transactions: one get/put pair is one RMW transaction. Exact get/put counts are recorded in each row log.

| Workload | Placement | Successful rows | Mean measured time | Mean throughput | Mean max RSS |
|---|---|---:|---:|---:|---:|
| f | native | 1 | 11.475s | 34.858M op/s | 31.130GiB |
| f | local | 1 | 11.275s | 35.478M op/s | 30.196GiB |
| f | target | 1 | 7.739s | 51.686M op/s | 30.196GiB |

### Complete Local/CXL Pairs

| Workload | Repeat | Local | CXL target | CXL vs local |
|---|---:|---:|---:|---:|
| f | 1 | 35.478M op/s | 51.686M op/s | +45.68% |

Mean of 1 paired deltas: **+45.68%**

## Static Compiler Selection

These sites were selected from the score and policy parameters and had their allocation calls rewritten. Selection does not mean that a call executes in this workload.

| Site | Kind | Function | Source | Object estimate | Score | Group | Selection signals |
|---:|---|---|---|---:|---:|---:|---|
| 68 | cxx-new | `hash` | `benchmark/xindex/XIndex-H/xindex_group_impl.h:80` | 96B | 5 | 6 | escapes-store, escapes-call, sync-atomic-rmw-or-cmpxchg-same-function, sync-atomic-or-volatile-store-same-function, sync-inline-asm-same-function |
| 71 | malloc | `allocate_leaf` | `benchmark/xindex/XIndex-H/xindex_buffer_impl.h:832` | 520B | 5 | 7 | escapes-store, sync-atomic-or-volatile-store-same-function, pthread-worker-reachable, large-allocation |
| 74 | malloc | `allocate_internal` | `benchmark/xindex/XIndex-H/xindex_buffer_impl.h:832` | 520B | 5 | 8 | escapes-store, sync-atomic-or-volatile-store-same-function, pthread-worker-reachable, large-allocation |
| 90 | cxx-new | `compact_phase_1` | `benchmark/xindex/XIndex-H/xindex_group_impl.h:246` | 64B | 6 | 3 | escapes-return, escapes-store, escapes-call, sync-atomic-or-volatile-store-same-function, pthread-worker-reachable |
| 97 | cxx-new | `insert_ptr` | `benchmark/xindex/XIndex-H/xindex_group_impl.h:149` | 96B | 7 | 1 | escapes-store, escapes-call, sync-atomic-rmw-or-cmpxchg-same-function, sync-atomic-or-volatile-store-same-function, sync-inline-asm-same-function, pthread-worker-reachable |
| 98 | cxx-new | `insert_ptr` | `/usr/include/c++/11/ext/new_allocator.h:127` | 8B | 6 | 4 | escapes-store, sync-atomic-rmw-or-cmpxchg-same-function, sync-atomic-or-volatile-store-same-function, sync-inline-asm-same-function, pthread-worker-reachable |
| 99 | cxx-new | `put` | `benchmark/xindex/XIndex-H/xindex_group_impl.h:113` | 96B | 7 | 2 | escapes-store, escapes-call, sync-atomic-rmw-or-cmpxchg-same-function, sync-atomic-or-volatile-store-same-function, sync-inline-asm-same-function, pthread-worker-reachable |
| 100 | cxx-new | `put` | `/usr/include/c++/11/ext/new_allocator.h:127` | 8B | 6 | 5 | escapes-store, sync-atomic-rmw-or-cmpxchg-same-function, sync-atomic-or-volatile-store-same-function, sync-inline-asm-same-function, pthread-worker-reachable |

## Runtime-Active CXL Sites

The following selected sites actually allocated objects in target row `f/r1`. Their arena slabs were bound to the CXL target node.

| Site | Function | Object | Allocations | Requested payload | Assigned arena |
|---:|---|---:|---:|---:|---:|
| 68 | `hash` | 96B | 26395417 | 2.360GiB | 3.148GiB |
| 71 | `allocate_leaf` | 520B | 26395622 | 12.783GiB | 14.164GiB |
| 74 | `allocate_internal` | 520B | 143 | 0.000GiB | 0.002GiB |

Runtime-active site IDs: `68,71,74`. Selected but inactive in this trace: `90,97,98,99,100`.

## Placement and Safety Validation

| Workload | Repeat | Placement | Status | Requested node | Resident | Majority node | Fallbacks | Swaps |
|---|---:|---|---|---:|---:|---:|---:|---:|
| f | 1 | local | ok | 0 | 17.310GiB | 0 | 0 | 0 |
| f | 1 | target | ok | 2 | 17.310GiB | 2 | 0 | 0 |

`Resident` is the physical memory occupied by the selected-site arena. `Assigned arena` also includes slot padding and slab granularity, so it can exceed requested object payload. A trustworthy placement row should be `ok`, have majority node equal to requested node, and report zero fallbacks and swaps.
