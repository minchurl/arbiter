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
- LLVM/MLIR development build or package that provides:
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

Then configure and build with Ninja:

```sh
cmake -S . -B build-ninja -G Ninja \
  -DMLIR_DIR="$(llvm-config --cmakedir | sed 's#/llvm$#/mlir#')"

cmake --build build-ninja --target arbiter-opt
```

Try the rewrite pipeline:

```sh
./scripts/smoke.sh
```

## Docs

- [Overview](docs/overview.md)
