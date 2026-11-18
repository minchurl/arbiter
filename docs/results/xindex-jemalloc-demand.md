# Jemalloc extents without a pre-reserved pool

This experiment compares the bounded jemalloc runtime at `9d90964` with the
same site-aware allocation ABI backed by demand-mapped jemalloc extents.
The earlier custom-slab-to-jemalloc experiment is separate:
[slab versus jemalloc](xindex-jemalloc.md).

## Final runtime: failure contracts and one full-trace pair

The final runtime adds failure diagnostics and preserves the supported allocation
APIs' failure behavior without restoring an allocation fallback:

| API | Failure behavior |
|---|---|
| malloc / calloc | NULL and errno; calloc overflow reports ENOMEM |
| ordinary new / new[] (including aligned) | invoke new_handler, retry the same arena if it returns, otherwise throw bad_alloc when no handler remains |
| nothrow new / new[] (including aligned) | catch exceptions from the throwing helper and return NULL |
| selected mmap | MAP_FAILED and errno; a failed mbind releases the new mapping |

The compiler now distinguishes these helpers and preserves invoke unwind edges
and operand bundles. A compiled/re-written fixture exercises catch blocks,
all eight standard new signatures, zero-size allocation, calloc overflow,
new_handler recovery and exceptions. Boundary tests inject mbind EPERM on nodes
0 and 2 and verify its errno survives both heap and mmap failure paths.
[C++ allocation contract](https://eel.is/c++draft/new.delete.single)

Failures emit API family, site, size/alignment, configured node, stage and errno.
For example, the injected binding test reports `api=malloc site=200 bytes=96
alignment=64 target_node=2 stage=mbind errno=1`. The final failed allocation is
reported; unsuccessful jemalloc extent probes followed by success are not logged
as allocation failures. No diagnostics are printed for successful requests.
These handlers cover failures returned to the runtime; they do not guarantee
recovery from process termination or memory exhaustion during later page faults.

Runtime C++/headers now total **650 lines**, versus **1,294** on main:
**644 fewer lines (49.77%)**. Failure handling adds 98 lines to the intermediate
552-line strict-only version. The compiler rewrite and tests are counted
separately. The direct backend and per-pointer side table remain removed.

Exactly **one Local/CXL pair**, with one full 100M-load / 400M-operation
trace pass per placement, was run on the final binary. No additional
performance repeats or fresh baseline runs were performed.

| Placement | Earlier main mean, 4 runs (M tx/s) | Earlier pool-removal mean, 4 runs (M tx/s) | Final, 1 run (M tx/s) | vs main mean | vs pool-removal mean |
|---|---:|---:|---:|---:|---:|
| Local | 26.894 | 26.335 | 26.468 | -1.58% | +0.51% |
| CXL | 47.029 | 44.855 | 43.274 | -7.98% | -3.52% |

Final CXL/Local throughput ratio: **+63.49%**.
Both final results are below the earlier main means, especially CXL.
This is a single-run comparison to historical controls, not a confirmed
speedup or proof that the code change caused the regression. The earlier
demand-runtime CXL range was 40.970–48.088 M tx/s; this final observation
falls within that range. No result was discarded or rerun.

The CPU/ordinary memory placement, 31 foreground + 1 background threads,
64 GiB cgroup limit, zero swap, policy and complete traces match the earlier
experiment. XIndex was rewritten again with the updated compiler: after
removing debug metadata and normalizing the new helper name/declarations,
its IR matches the original comparison bitcode. No workload or selection
change was introduced. Compilation and other benchmark jobs were stopped
before these measurements. Page caches were not explicitly dropped.

Both runs completed 400M operations, made 52,791,182 selected allocations,
used sites `68,71,74`, and produced digest `0x7474b8e9d3962859` for the same
4,096 sampled keys. All 5,000,778 located private arena pages were on the
requested node. Allocation-failure diagnostics, fallback, page-query errors
and swap were all zero. Peak process RSS was 31.993 GiB in both runs.

The retained [final measurements](../../results/xindex/ycsb-a/jemalloc-strict-20261119/README.md)
include hashes, rows, selected sites, validation extracts and the driver.

## Intermediate strict-only runtime (552 lines, not measured)

A subsequent cleanup removes the direct heap backend, non-strict retry,
per-pointer side table and failure-category plumbing. The only heap path is
jemalloc with strict NUMA binding. `ARBITER_TARGET_NODE` is required; old
`arena`/`strict=1` settings remain accepted, while `direct`/`strict=0` fail
with a diagnostic. Ordinary `free` and every matching C++ `delete` ABI remain.
`fallback_allocations=0` is a compatibility field, not a failure counter.

Selected `mmap` now uses `mmap` plus `mbind`, preserving protection flags;
pre-populated pages use MOVE/STRICT binding. Failed binding unmaps the range.
`munmap` forwards directly, so partial unmaps need no ownership table. Only
private anonymous, non-fixed mappings are accepted by the selected wrapper;
other forms fail instead of silently relaxing the placement contract.
[Linux mbind semantics](https://man7.org/linux/man-pages/man2/mbind.2.html)
Heap-extent reports do not include these separate mmap allocations.

| Runtime source | Main (`9d90964`) | Pool removal, measured | Strict-only, intermediate |
|---|---:|---:|---:|
| `arbiter_jemalloc_arena.cpp` | 642 | 356 | 386 |
| `arbiter_runtime_site.cpp` | 496 | 491 | 118 |
| Side table implementation/header | 95 | 95 | 0 |
| Other headers | 61 | 60 | 48 |
| **Total** | **1,294** | **1,002** | **552** |

Intermediate reduction: **742 lines (57.34%)** from main, or **450 lines (44.91%)**
from the measured pool-removal version. These are physical C++/header lines,
including comments and blanks; no implementation was moved out of runtime.

Validation was deliberately limited to a runtime build and short tests on
nodes 0 and 2: heap/calloc/alignment and C++ delete ABI checks, concurrent
allocation/free/reuse, bound mmap and partial munmap, injected binding failures,
invalid/missing node settings, rejected legacy backend settings, and accepted
legacy arena/strict settings. Logs are under `build/jemalloc-demand/strict-checks/`.
**No XIndex or allocation-performance measurements were rerun for this cleanup.**
The throughput tables and hashes below describe the earlier 1,002-line version,
not the intermediate 552-line runtime or final 650-line runtime.

## Measured pool-removal implementation

Each selected allocation site still has an explicit jemalloc arena, the same
minimum 64-byte alignment, and `MALLOCX_TCACHE_NONE` on allocation/free. The
compiler, selection policy and XIndex workload are unchanged.

The extent hook now uses an aligned anonymous `mmap`, binds it with
`mbind(MPOL_BIND)` before returning it to jemalloc, and records the mapping.
jemalloc owns size classes, reuse and allocation statistics. An ordered
extent registry routes ordinary versus selected frees without reading
arbitrary pointers or keeping a per-object hash table. All backing mappings
and hooks remain alive through static destruction and are reclaimed by the
OS at process exit; jemalloc can purge physical pages and reuse extents.

Removed: the large virtual reservation, bump offset, fixed pool capacity,
retained-growth cap, page-owner table, per-object live bitmap, hot-path
allocation/live/peak counters, fixed object shape and half-chunk size limit.
One site can now allocate mixed sizes/alignments, including large objects.

Intentional contract changes:

- `ARBITER_ARENA_RESERVE_BYTES` and `ARBITER_ARENA_SLAB_BYTES` are obsolete and
  ignored with a warning. Use cgroup/process memory limits instead.
- The runtime no longer diagnoses invalid/interior/double frees. These are
  undefined, as with ordinary `free`; valid pointer ownership and matching
  C++ allocation/deallocation ABIs remain supported.
- Allocation reports use jemalloc statistics; reporting requires a
  stats-enabled jemalloc. Peak-live and cumulative payload/slot-byte counters
  are removed. Historical CSV columns for removed fields remain empty.
- Per-site `object_bytes=0` denotes mixed requested sizes. `allocated_bytes`
  is current usable allocation size, not requested payload or RSS.

## Measured version code size

Physical source lines, including comments and blank lines, compared with
`9d90964`; C++ formatting remains LLVM style. No code was moved out of runtime
to obtain this reduction.

| Scope | Bounded runtime | Demand runtime | Reduction |
|---|---:|---:|---:|
| `arbiter_jemalloc_arena.cpp` | 642 | 356 | 286 (44.55%) |
| All runtime C++ and headers | 1,294 | 1,002 | 292 (22.57%) |

The measured version still included the direct-allocation backend, side table
and public C/C++ ABI wrappers in its total. Tests, runner adjustments, documentation and measurements are
counted separately from runtime code.

## Full XIndex/YCSB-A comparison (before strict-only cleanup)

| Placement | Bounded mean (M tx/s) | Demand mean (M tx/s) | Change |
|---|---:|---:|---:|
| Local / node 0 | 26.894 | 26.335 | -2.08% |
| CXL / node 2 | 47.029 | 44.855 | -4.62% |

Both means decreased in this run set; this is **not a demonstrated speedup or
a confirmed performance-neutral change**. Candidate variability is higher,
especially on CXL. Four repeats do not establish whether the mean regressions
are reproducible. No runs were discarded.

| Placement / runtime | Min–max (M tx/s) | Sample SD (M tx/s) |
|---|---:|---:|
| Local / baseline | 26.666–27.245 | 0.248 |
| Local / candidate | 24.921–27.344 | 1.040 |
| CXL / baseline | 45.360–48.090 | 1.265 |
| CXL / candidate | 40.970–48.088 | 3.028 |

The CXL/Local ratio of mean throughput is +74.87% for the
bounded runtime and +70.33% for the demand runtime.
The placement benefit remains visible; it does not erase the regression against
the corresponding bounded-runtime controls.

Mean peak process RSS falls from 32.051 GiB to 31.993 GiB
(58.8 MiB lower). Selected-arena private residency is essentially
unchanged: 20,484,218,880 versus 20,483,186,688 bytes. The old page-owner/live
metadata is gone; removing the virtual reservation does not free 24 GiB of RSS.
Mapped backing reported as `assigned_bytes` increases from 20,587,741,184 to
23,578,279,936 bytes because jemalloc now chooses its own growth sizes. The old
runtime additionally reserved its complete 24 GiB address range up front.

Each process loads 100 million records and consumes the complete 400 million
transaction trace once, with 31 foreground workers and one background worker.
CPU and ordinary heap memory are on node 0; selected objects use either node
0 or CXL node 2. Each process has `MemoryMax=64G` and `MemorySwapMax=0`.
The baseline also retains its original 24 GiB virtual pool limit; the new
runtime has no fixed virtual pool. Both use system jemalloc 5.2.1 on the same
Xeon Gold 6548Y+ host, Linux 6.6.92+, with no `MALLOC_CONF` override.

Both executables are linked from the exact same rewritten LLVM bitcode
(`874a18c747b452d48566dd61b750f3811edfd7868cefdb8c3a037210606fb59e`). The baseline
executable reproduces the previous binary hash. Four runs per allocator and
placement use alternating orders:

1. baseline Local, demand Local, demand CXL, baseline CXL;
2. demand Local, baseline Local, baseline CXL, demand CXL;
3. repeat the first order;
4. repeat the second order.

Each row uses a fresh process. No other benchmark or compilation runs during
these measurements. Filesystem caches are not explicitly dropped; the first
baseline row has a longer input-loading wall time. Throughput is measured
after index construction and excludes input parsing, construction and exit
reports. Do not interpret the first-row wall-time difference as allocator
speedup. Allocation work is largely outside the timed transaction loop.

All 16 full runs completed 400 million operations, with 52,791,182 selected
allocations, active sites `68,71,74`, and the same 4,096-key state digest
`0x7474b8e9d3962859`. Every located private selected-arena page was on the
requested node. Fallback, residency-query errors and swaps were zero.

The runtime/compiler smoke suite and a separate 200K-load/1M-operation
native/Local/CXL check passed, with matching state digest
`0x9d30d99a719185fa`. Boundary checks cover mixed sizes at one site, allocations
larger than the former chunk limit, alignment up to 1 MiB, all touched pages,
ordinary/mmap pointer ownership, cross-thread frees, reuse, strict failure
under injected `mbind` errors, and frees from a static destructor after the
exit report. Expected allocation failures in fault/invalid-input tests are
not benchmark fallbacks.

The edited protected XIndex runner and summary parser passed a second
200K/1M native/Local/CXL run. B-tree/micro adapters build successfully, and
microbenchmark tests passed for 0%, 50% and 100% reads, contention and invalid
arguments. A one-second native/Local/CXL micro smoke run confirmed operation
counts, zero fallback/query errors, and table placement on node 0/2 while
ballast remained on node 0. Its timing is not a performance comparison.


## Supplemental allocation/free/reuse check

The unchanged `tests/llvm/arbiter-slab-arena-smoke.cpp` was linked separately
against the two frozen runtime archives. Each process allocates two million
96-byte objects using eight threads, writes and verifies their NUMA pages,
frees from replacement threads, then allocates/frees two million objects
again. Minimum alignment is 64 bytes. Three alternating-order pairs per
node ran after the full XIndex measurements; arena reporting was disabled.
The baseline used a 512 MiB reservation and 2 MiB chunks. CPU/ordinary
memory remained on node 0. All 12 runs passed placement/reuse checks.

| Placement | Bounded mean wall (s) | Demand mean wall (s) | Time change |
|---|---:|---:|---:|
| Local | 5.510 | 5.680 | +3.09% |
| CXL | 5.340 | 5.630 | +5.43% |

Lower elapsed time is better. These short whole-process timings include
page faults, writes, sorting, NUMA queries and thread startup; they do not
isolate malloc/free latency. Means again favor the bounded runtime, with
substantial run variation. The demand runtime also has a mutex-protected
extent lookup on free; this test does not isolate that cost or establish
the cause of the XIndex throughput difference. Retained results include
`lifecycle.csv` and `lifecycle.py` (copy the driver under
`build/jemalloc-demand/` before running).

## Placement accounting

All touched object pages are independently queried in the runtime tests.
At process exit, `mincore` filters mapped resident pages and `move_pages`
locates private physical pages. The kernel returns `-EFAULT` for shared zero
pages; after checking that the address remains mapped, the report records
them separately as `zero_pages`, not private NUMA memory. Other failures stay
errors. Full candidate runs each report six such pages. This avoids writing
to or faulting extra pages just to produce a residency report.
[Linux page-state definitions](https://man7.org/linux/man-pages/man2/move_pages.2.html)

`assigned_bytes` is virtual backing mapped for jemalloc, including retained
capacity and arena metadata. It can increase because jemalloc now controls
extent growth, even when resident bytes stay essentially unchanged. Removing
the pool does not remove jemalloc's own retention policy.

## Reproduction

Freeze the baseline runtime library at `9d90964`, build the candidate runtime
in Release mode, and link both against the same existing
`ycsb_bench.arbiter.bc` using `scripts/build-xindex-llvm.sh`'s link flags. Keep
both binaries unchanged throughout the comparison. The retained manifest
records the source, bitcode and executable hashes.

The comparison driver expects the following under the repository root:

```text
build/jemalloc-demand/baseline/{libarbiter_runtime.a,arbiter_jemalloc_arena.cpp,ycsb_bench.arbiter.bc,ycsb_bench-arbiter}
build/jemalloc-demand/candidate/{libarbiter_runtime.a,arbiter_jemalloc_arena.cpp,ycsb_bench-arbiter}
```

Copy the retained `compare.py` to `build/jemalloc-demand/compare.py` and run
`python3 build/jemalloc-demand/compare.py --rounds 4`. It checks state digests,
operation/allocation counts, active sites, all located pages, fallback counts
and swap after each row. It refuses an existing result directory unless
`--resume` is given and verifies the manifest and completed order before
continuing. Raw logs and binaries stay under ignored `build/jemalloc-demand/`;
compact measurements and validation extracts are retained in
`results/xindex/ycsb-a/jemalloc-demand-20261118/`.
