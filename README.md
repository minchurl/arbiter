# Arbiter

Arbiter selects allocation sites with static evidence of cache-coherence risk
and places their objects in local or CXL-attached NUMA memory.
LLVM chooses the sites; jemalloc manages small objects; NUMA extent hooks
control their backing pages. Selection is a heuristic, not hardware HITM sampling.

```text
C++ -> LLVM IR -> score allocation sites -> rewrite selected calls
    -> NUMA-bound jemalloc extents -> compare Local and CXL
```

## Start here

| Question | Read |
|---|---|
| How does it work? Which code should I review? | [Architecture and code map](docs/overview.md) |
| How do I build, run and validate it? | [Benchmark guide](docs/benchmarks.md) |
| What improved, what did not, and why? | [Results and design history](docs/results.md) |
| Which selection config should I use? | [Config guide](configs/hitm-seed/README.md) |
| Where are the original measurements? | [Evidence index](results/README.md) |

## Setup

Linux, CMake 3.20+, Ninja, C++17, LLVM 18, libnuma, jemalloc 5 and Intel MKL
are required for XIndex. Full A/F traces need about 26 GB of uncompressed disk
space plus the compressed package; protected runs use systemd user scopes.

```sh
sudo apt install cmake ninja-build make gcc clang-18 llvm-18-dev \
  libnuma-dev libjemalloc-dev git-lfs zstd numactl

git lfs install
./scripts/setup-benchmarks.sh
```

Setup restores traces, builds the compiler/runtime and XIndex/GUPS, and runs
short checks. MKL defaults to `/opt/intel/oneapi/mkl/latest`; see the
[guide](docs/benchmarks.md#setup-and-data) for overrides and a manual build.

## Run

```sh
./scripts/run-xindex-a-demo.sh   # A: 50% read / 50% update
./scripts/run-xindex-f-demo.sh   # F: 50% read / 50% read-modify-write
```

Each command builds and runs Local once, then CXL once: 100M load records and
one complete 400M-transaction pass per process. These are full runs, not smokes.
Defaults use CPU/ordinary memory node 0 and CXL node 2.
[B-tree and microbenchmark commands](docs/benchmarks.md#b-tree-and-coherence-microbenchmark)
are separate because they use external source directories.
[Libcuckoo](docs/benchmarks.md#libcuckoo) adds the upstream mixed workload and an
existing-key contention driver, using the same automatic selection policy.

## Current status

The runtime uses strict jemalloc arenas with mappings acquired on demand.
There is no large reserved pool or allocation fallback; allocation failures
preserve the supported C/C++ API contracts and report their cause.

XIndex A/F have shown CXL placement gains on the measured host. The corrected
microbenchmark's default workload gains nothing from CXL placement, but partial
ballast placement helps a smaller, more contended hot set. B-tree's automatic
policy selects no objects. See the
[results](docs/results.md) for versions, negative findings and measurement limits.

Libcuckoo's lock storage is now discovered through `std::thread` and object-field
accesses without new selection parameters. Its placement results show no
consistent CXL gain; separate TTAS experiments improve highly contended cases.
XIndex and microbenchmark selection and rewritten bitcode remain unchanged.

An opt-in companion report now finds other allocations accessed in the same
worker loop. A separate runtime API can interleave a selected heap site or cap
its cumulative CXL backing, then use DRAM. Default seed selection is unchanged;
candidate discovery and a byte cap do not by themselves predict a speedup.
See [experimental placement](docs/benchmarks.md#experimental-companion-placement).

Keep current behavior in the architecture guide, commands in the benchmark
guide, and conclusions in the results guide. Add experiment data to `results/`
and index it there instead of adding another narrative report.
