# XIndex Runtime and Correctness Validation Plan

Status: completed on 2026-10-21; see
[`docs/results/xindex-runtime-correctness.md`](results/xindex-runtime-correctness.md)

Branch: `validation/xindex-runtime-correctness`
Baseline: `main` at `9c2e865`

## 1. Why this validation comes first

The retained XIndex/YCSB-A result shows a large and repeatable throughput
difference when the runtime-active sites 68 and 71 are placed on CXL. The
four-pair site ablation measured:

| Policy | Local | CXL | Mean paired delta |
|---|---:|---:|---:|
| Site 68 only | 26.893M op/s | 39.367M op/s | +46.35% |
| Site 71 only | 26.924M op/s | 40.597M op/s | +50.78% |
| Sites 68+71 | 26.290M op/s | 50.092M op/s | +90.79% |
| raw-046, sites 68+71+74 | 26.287M op/s | 50.324M op/s | +91.53% |

Those rows completed with zero arena fallback, swap, OOM, and placement-query
errors. The runtime-active allocations were fixed-size: site 68 used a 96-byte
ordinary C++ allocation, while sites 71 and 74 used 520-byte `malloc`
allocations. This means the dynamic-size failure seen in the first broad sweep
does not directly explain the retained result.

However, two correctness gaps prevent treating the throughput result as fully
validated:

1. The global heap deallocation rewrite does not preserve the ordinary,
   array, sized, and aligned C++ delete ABIs as separate fallback paths.
2. The XIndex driver increments throughput after every attempted operation but
   does not retain success/failure counts or a deterministic final checksum.

The next work therefore validates runtime semantics and benchmark correctness
before returning to libcuckoo or collecting more performance data.

## 2. Questions to answer

1. Does a rewritten allocation preserve the requested size and alignment?
2. Does each tracked or untracked pointer reach the correct matching free or
   C++ delete path?
3. Do native, rewritten-Local, and rewritten-CXL XIndex runs complete the same
   operations successfully and produce the same logical result?
4. After those checks pass, does the Site 68+71 Local/CXL throughput difference
   remain?

This work does not yet attempt to prove that HITM reduction is the cause.
Hardware coherence counters are a later gate.

## 3. Known risk boundaries

### 3.1 Fixed-slot arena

The arena creates one fixed `(size, alignment)` class per site. A later request
with a different size or alignment is rejected. Objects larger than the arena
slot limit are also rejected. This behavior is appropriate for XIndex sites
68, 71, and 74 because their observed sizes are constant, but it is not a
general solution for libcuckoo's dynamically sized lock array.

The XIndex build controller must continue to reject every automatically
selected site whose allocation size is non-constant. The policy option
`ARBITER_HITM_INCLUDE_DYNAMIC_SIZE=0` only removes the dynamic-size score; it is
not a hard exclusion, so the independent compiler-report gate remains
necessary.

### 3.2 Direct backend

The direct backend accepts a runtime size, but the current implementation does
not completely preserve requested alignment and aligned-delete fallback
semantics. It must not be used for libcuckoo Site 43 until the ABI tests below
pass.

### 3.3 Existing XIndex result

The selected runtime-active sites reported zero frees during the measured
processes, and none uses aligned allocation. An aligned site was selected
statically but remained runtime-inactive. The delete ABI gap is therefore not
an obvious explanation for the approximately 90% paired delta, but the binary
still contains a global deallocation rewrite and must be revalidated.

## 4. Validation stages

### Stage 0: freeze the existing evidence

Before changing implementation code:

- retain the existing site-ablation result and its raw logs unchanged;
- record the source commit and SHA-256 of native and rewritten binaries;
- record the selected static sites and runtime-active sites;
- preserve the per-row throughput, arena, RSS, swap, and NUMA-residency data;
- label the existing result `provisional-correctness` rather than deleting or
  rewriting it.

Gate: the historical result must remain reproducible from immutable inputs.

### Stage 1: allocation/deallocation ABI tests

Add a small C++ runtime test that exercises each relevant pair:

- ordinary `new` / `delete`;
- ordinary `new[]` / `delete[]`;
- aligned `new` / aligned `delete`;
- aligned `new[]` / aligned `delete[]`;
- sized delete variants when emitted by the compiler;
- aligned and sized delete variants together;
- `malloc` / `free` and `calloc` / `free`.

Each pair must cover:

- a pointer tracked by the direct backend;
- an untracked pointer passing through a rewritten fallback helper;
- an arena-owned pointer when the allocation shape is arena-compatible;
- an unowned pointer while strict arena mode is enabled.

Check the returned alignment, write/read the complete allocation, verify
destructor counts, and ensure exactly one matching release occurs. Use a small
ASan/UBSan build where compatible, plus non-sanitized NUMA smoke tests.

Expected implementation rule: the rewrite must preserve the original delete
variant for the untracked fallback. It must not collapse every C++ delete into
an unaligned one-argument fallback.

Gate: all ABI cases pass without sanitizer findings, invalid frees, leaks, or
alignment violations.

### Stage 2: arena invariant tests

Extend the focused arena tests to make the supported boundary explicit:

- repeated allocations with the same site, size, and alignment succeed;
- a size or alignment change at the same site is rejected in strict mode;
- an object beyond the slot limit is rejected;
- fixed-size allocations are recycled correctly after free;
- fallback counters remain zero in a valid strict-arena run;
- the majority resident NUMA node matches the requested node.

Add a build/report check that fails closed when an XIndex performance policy
selects a non-constant allocation, even if that site reaches the score
threshold using non-size evidence.

Gate: the arena failure mode is detected before running the benchmark and all
supported fixed-size cases pass.

### Stage 3: XIndex operation correctness instrumentation

Instrument the benchmark without changing the operation sequence. Maintain
per-thread counters and aggregate them outside the timed hot path:

- attempted and successful reads;
- attempted and successful updates/inserts;
- attempted and successful removes, if present;
- unexpected operation codes;
- total attempted operations.

For YCSB-A, the loaded keys and transaction trace should allow an explicit
expectation for read/update success. Do not count a failed operation as a
successful throughput operation.

After the timed region, compute a deterministic validation digest from a fixed
set of keys and their values. The validation key set, order, and hash must be
identical across native, Local, and CXL runs. Record the digest and operation
counters separately from throughput so validation work is not timed.

Gate: native, rewritten-Local, and rewritten-CXL runs report identical
operation counts, expected success counts, and final validation digest.

### Stage 4: short end-to-end matrix

Run a small trace first, using fresh processes:

| Binary/policy | Placement | Purpose |
|---|---|---|
| native | default Local | semantic reference |
| Site 68+71 rewritten | Local | rewrite and arena control |
| Site 68+71 rewritten | CXL | placement under test |
| raw-046 rewritten | Local | retained-policy control |
| raw-046 rewritten | CXL | retained-policy control |

Use the same rewritten binary for each Local/CXL pair. Require zero fallback,
swap, placement-query errors, and unexpected allocation sites. Stop immediately
on any operation-count or digest mismatch.

Gate: every row is semantically identical before a full-trace run is allowed.

### Stage 5: full-trace confirmation

Only after Stages 1--4 pass:

1. Run the complete 100M-record load and 400M-operation YCSB-A transaction
   trace exactly once per process; do not use cyclic replay.
2. Re-detect CPU and NUMA topology. Keep benchmark workers on the intended CPU
   set and move interactive/OS work to the separate control CPU/node where the
   machine permits it.
3. Use `MemoryMax=64G` and `MemorySwapMax=0`.
4. Alternate Local/CXL order.
5. Start with one diagnostic pair. If correctness matches, run four independent
   Site 68+71 pairs for comparison with the retained ablation result.
6. Record operation counters and digest together with throughput, maximum RSS,
   allocation counts, arena bytes, fallback counts, swap, and NUMA residency.

Gate: correctness agrees in every row and the paired throughput result is
stable enough to compare with the retained four-pair estimate.

## 5. Decision table

| Outcome | Interpretation | Action |
|---|---|---|
| ABI tests and XIndex correctness pass; throughput persists | Existing result is supported | retain result, then return to libcuckoo |
| Correctness passes; throughput disappears after ABI fix | Previous result depended on implementation behavior | supersede old performance claim |
| Local/CXL operation counts or digest differ | Benchmark result is not valid | stop performance work and debug XIndex/runtime |
| ABI tests fail before benchmark | Runtime rewrite is not generally safe | fix ABI and rerun unit gates first |
| Correctness and throughput pass but HITM is unmeasured | Placement effect only | collect C2C/HITM counters before causal claim |

## 6. Planned deliverables

- focused allocation/deallocation ABI tests;
- explicit fixed-slot arena boundary tests;
- XIndex per-operation success counters and deterministic validation digest;
- a fail-closed short validation driver;
- a one-pass full-trace confirmation driver;
- `docs/results/xindex-runtime-correctness.md` containing commands, binary
  hashes, correctness evidence, and the final decision.

The runtime/correctness gates above passed. Further generality work can use the
validated runtime, while a causal HITM claim still requires hardware counters.
