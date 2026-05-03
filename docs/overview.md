# Arbiter Overview

This document is the source of truth for Arbiter's current design.

## Overview

Arbiter is a compiler-assisted object placement system for tiered memory environments.

The system identifies memory objects that may suffer from coherence and contention overhead, and places selected objects on an alternative memory node such as CXL memory or a remote NUMA node.

The first target is allocation-time placement based on static compiler analysis. Arbiter does not move objects after the program starts running.

## Motivation

### Problem

In NUMA systems, placing data close to the CPU is usually beneficial. However, this assumption can break down for write-heavy shared objects.

When multiple cores or sockets repeatedly write to the same object, the object can cause cache-line ownership transfers, invalidations, HITM events, and interconnect traffic. In this case, the main cost may come from coherence and contention rather than raw memory latency.

Arbiter explores whether such objects can benefit from being placed on a different memory tier.

### Hypothesis

Some write-heavy shared objects may perform better when placed on a less contended memory node, even if that node has higher access latency.

This is the main hypothesis to test. It should not be assumed to hold for all workloads or all objects.

## Compiler Design

Arbiter separates object selection from allocation rewriting.

### Candidate Selection

Candidate selection decides which allocation-like objects should be placed on the target memory node. This decision is made statically during compilation.

The first version marks all eligible allocations. Later versions can use more selective static policies:

- manually annotated objects
- static write-intensity analysis
- static sharing or escape analysis
- parallel-region-aware analysis
- static object scoring based on write intensity and sharing likelihood

All versions should produce the same output: a marked allocation or an object-level placement decision.

### Allocation Rewriting

Allocation rewriting consumes the selection result and rewrites selected allocation/deallocation sites into Arbiter dialect operations.

```text
memref.alloc
  -> arbiter.alloc
  -> arbiter_alloc(...)

memref.dealloc
  -> arbiter.dealloc
  -> arbiter_dealloc(...)
```

`arbiter.alloc` is backend-independent. It can be lowered to a NUMA allocator in the current setup, and later to a CXL-backed allocator if real CXL memory is available.

The compiler does not generate special CXL load/store instructions. CXL memory and NUMA memory are accessed through normal CPU load/store instructions after the object has been allocated on the target node.

At runtime, placement labels such as `remote` and `cxl` are implemented by
allocating selected objects from a configured target memory node. This keeps the
compiler-facing policy labels separate from the concrete machine setup: on
NUMA-only servers, CXL-like experiments can use a remote NUMA node as the target
node.

### Input Definition

Arbiter's core compiler takes MLIR as input:

```text
arbiter-opt input.mlir -> transformed.mlir
```

The first target input is memref-level MLIR, because allocation objects, stores, loops, and parallel regions are still visible enough for static analysis.

C/C++ support should enter through a frontend that emits suitable MLIR, preferably `cgeist`. Arbiter does not treat LLVM-dialect malloc rewriting as the core input path.

### Input IR Strategy

Candidate selection should run at the highest MLIR level that still exposes allocation objects and structured memory accesses.

The first prototype assumes memref-level allocation objects:

```text
memref.alloc
  -> arbiter.candidate
  -> arbiter.alloc
  -> arbiter_alloc(...)

memref.dealloc
  -> arbiter.dealloc
  -> arbiter_dealloc(...)
```

This level is useful because object identity and memory accesses are explicit. It also makes it easier to reason about stores inside loops, parallel regions, and other structured control-flow constructs.

For broader C/C++ support, the frontend should preserve allocation objects at a level where Arbiter can analyze and rewrite them. If a frontend lowers everything to LLVM-dialect malloc calls before Arbiter runs, the core analysis input is already too low-level for the first design.

### Example Transformation

The first prototype changes allocation and deallocation operations only. Memory accesses remain ordinary `memref.load` / `memref.store` operations and later become normal CPU load/store instructions.

Original MLIR:

```mlir
%N = arith.constant 1024 : index
%A = memref.alloc(%N) : memref<?xi32>
memref.store %v, %A[%i] : memref<?xi32>
```

After static candidate selection:

```mlir
%N = arith.constant 1024 : index
%A = memref.alloc(%N) {arbiter.candidate} : memref<?xi32>
memref.store %v, %A[%i] : memref<?xi32>
```

After allocation rewriting:

```mlir
%N = arith.constant 1024 : index
%A = arbiter.alloc(%N) {target = "remote"} : memref<?xi32>
memref.store %v, %A[%i] : memref<?xi32>
arbiter.dealloc %A {target = "remote"} : memref<?xi32>
```

After lowering to LLVM dialect, schematically:

```mlir
%size = ...  // N * sizeof(i32)
%align = llvm.mlir.constant(64 : i64) : i64
%policy = llvm.mlir.constant(1 : i32) : i32
%raw = llvm.call @arbiter_alloc(%size, %align, %policy)
       : (i64, i64, i32) -> !llvm.ptr
llvm.call @arbiter_dealloc(%raw, %size, %policy)
       : (!llvm.ptr, i64, i32) -> ()
```

In an actual memref lowering path, `arbiter_alloc` returns the underlying buffer pointer, and the lowering must still construct or update the memref descriptor used by later `memref.load` / `memref.store` lowering.

At machine level, later memory accesses are still normal load/store instructions. The placement effect comes from the pointer returned by `arbiter_alloc`.
