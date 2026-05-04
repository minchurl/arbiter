# Arbiter

Arbiter is a compiler-assisted object placement system for tiered memory environments.

It identifies allocation objects that may suffer from coherence and contention overhead, then places selected objects on an alternative memory node such as remote NUMA memory or CXL memory.

The first target is static, allocation-time placement. Arbiter does not move objects after the program starts running.

## Prerequisites

Arbiter builds as an out-of-tree MLIR project. The compiler pipeline is centered
on MLIR input; source-level frontends can be integrated separately.

Required:

- CMake 3.20 or newer
- Ninja
- C++17 compiler, such as `clang++`
- LLVM/MLIR 18 development packages. LLVM 18 is required and is the default
  LLVM toolchain on Ubuntu 24.04 LTS.
  The toolchain must provide:
  - `LLVMConfig.cmake`
  - `MLIRConfig.cmake`
  - `llvm-config`
  - `mlir-tblgen`

Useful for local checks:

- `FileCheck`
- `mlir-opt`

`cgeist` can be used as a C/C++ frontend when source-level inputs need to be
translated into MLIR. A typical compiler path is:

```text
memref-level MLIR -> arbiter-opt -> transformed MLIR
```

## Build

Run:

```sh
./scripts/setup.sh
```

`scripts/setup.sh` defaults to LLVM 18 under `/usr/lib/llvm-18`. Set
`LLVM_PREFIX` if LLVM 18 is installed somewhere else.

On Ubuntu 24.04, install the baseline toolchain:

```sh
sudo apt install cmake ninja-build clang-18 llvm-18-dev mlir-18-tools libnuma-dev
```

Then configure and build with Ninja:

```sh
cmake -S . -B build-llvm18 -G Ninja \
  -DCMAKE_C_COMPILER=/usr/lib/llvm-18/bin/clang \
  -DCMAKE_CXX_COMPILER=/usr/lib/llvm-18/bin/clang++ \
  -DMLIR_DIR=/usr/lib/llvm-18/lib/cmake/mlir

cmake --build build-llvm18 --target arbiter-opt arbiter-runtime-smoke
```

Try the rewrite pipeline:

```sh
ARBITER_BUILD_DIR=build-llvm18 ./scripts/smoke.sh
```

## Runtime Placement

Arbiter-selected allocations are placed on the memory node configured by
`ARBITER_TARGET_NODE`.

When memory node `x` is reserved for Arbiter-selected allocations, keep ordinary
process allocations off that node and configure Arbiter to use it as the target:

```sh
numactl --membind='!x' \
  env ARBITER_TARGET_NODE=x \
  ./program
```

If `ARBITER_TARGET_NODE` is unset or node allocation is unavailable, the runtime
falls back to host allocation for local smoke tests.

On Linux systems with libnuma development headers, the build also provides a
placement checker:

```sh
cmake --build build-llvm18 --target arbiter-numa-placement

numactl --cpunodebind=0 --membind=0 \
  env ARBITER_TARGET_NODE=1 ARBITER_EXPECT_NODE=1 \
  build-llvm18/bin/arbiter-numa-placement
```

## Docs

- [Overview](docs/overview.md)
