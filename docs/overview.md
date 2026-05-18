# Arbiter Overview

This document is the source of truth for Arbiter's current design.

## Overview

Arbiter is a compiler-assisted placement system for coherence-sensitive memory objects in tiered memory environments.

The system identifies allocation-backed objects whose performance may be dominated by cache-coherence activity rather than raw memory access latency, and places selected objects on an alternative memory node such as CXL memory or a remote NUMA node.

The first target is allocation-time placement based on static compiler analysis. Arbiter does not move objects after the program starts running.

## Motivation

### Problem

In cache-coherent multicore systems, shared writable cache lines can become expensive because of coherence activity. NUMA and tiered-memory systems make this cost more visible and provide placement targets for Arbiter.

When multiple cores repeatedly access the same cache line and at least one core writes, ownership can move between cores, other cached copies can be invalidated, and coherence misses or interconnect traffic can increase.

Arbiter therefore focuses on coherence-sensitive objects: allocation-backed objects likely to create significant coherence overhead because they are shared, written, and accessed in parallel.

### Hypothesis

Some coherence-sensitive objects may perform better when placed on a different memory tier, even if that tier has higher access latency.

The hypothesis is not that CXL or remote NUMA memory eliminates cache coherence. Cacheable CPU loads and stores still participate in the coherence protocol regardless of where the backing memory is placed.

Instead, Arbiter tests whether object placement can change where coherence traffic is handled, how much pressure it creates on shared interconnects and memory controllers, and how much it interferes with other hot data. The expected benefit exists only when the reduction in coherence-related pressure is larger than the added latency penalty of the target memory tier.

This should not be assumed to hold for all workloads or all objects.

## Compiler Design

Arbiter separates object selection from allocation rewriting.

### Object Selection

Object selection decides which allocation-backed memory objects should be placed on the target memory node. This decision is made statically during compilation.

The first version may select all eligible allocation-backed objects to validate the rewrite and runtime placement path. Later versions should use more selective static policies:

- manually annotated objects
- static write-intensity analysis
- static sharing or escape analysis
- parallel-region-aware analysis
- cache-line and sub-object layout hints
- static object scoring based on coherence-sensitivity likelihood

All versions should produce the same output: a selected object or an object-level placement decision.

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

`arbiter.alloc` is backend-independent. It can be lowered to a node-backed allocator in the current setup, and later to a CXL-backed allocator if real CXL memory is available.

The compiler does not generate special CXL load/store instructions. CXL memory and NUMA memory are accessed through normal CPU load/store instructions after the object has been allocated on the target node.

At runtime, selected objects are allocated from a configured target memory node.
On NUMA-only servers, a remote NUMA node can serve as the target node for
CXL-like experiments.

### Input Definition

Arbiter's core compiler takes MLIR as input:

```text
arbiter-opt input.mlir -> transformed.mlir
```

The first target input is memref-level MLIR, because allocation objects, stores, loops, and parallel regions are still visible enough for static analysis.

C/C++ support should enter through a frontend that emits suitable MLIR, preferably `cgeist`. Arbiter does not treat LLVM-dialect malloc rewriting as the core input path.

### Input IR Strategy

Object selection should run at the highest MLIR level that still exposes allocation objects and structured memory accesses.

The first prototype assumes memref-level allocation objects:

```text
memref.alloc
  -> arbiter.select
  -> arbiter.alloc
  -> arbiter_alloc(...)

memref.dealloc
  -> arbiter.dealloc
  -> arbiter_dealloc(...)
```

This level is useful because object identity and memory accesses are explicit. It also makes it easier to reason about stores inside loops, parallel regions, and other structured control-flow constructs.

For broader C/C++ support, the frontend should preserve allocation objects at a level where Arbiter can analyze and rewrite them. If a frontend lowers everything to LLVM-dialect malloc calls before Arbiter runs, the core analysis input is already too low-level for the first design.

### Placement Granularity

The first implementation uses allocation-object granularity because `memref.alloc` gives Arbiter a clear compiler-visible object boundary.

This is a known limitation. A large allocation can contain cold regions, read-mostly regions, and coherence-heavy regions. Page-level or sub-object placement is future work.

### Example Transformation

The first prototype changes allocation and deallocation operations only. Memory accesses remain ordinary `memref.load` / `memref.store` operations and later become normal CPU load/store instructions.

Original MLIR:

```mlir
%N = arith.constant 1024 : index
%A = memref.alloc(%N) : memref<?xi32>
memref.store %v, %A[%i] : memref<?xi32>
```

After static object selection:

```mlir
%N = arith.constant 1024 : index
%A = memref.alloc(%N) {arbiter.select} : memref<?xi32>
memref.store %v, %A[%i] : memref<?xi32>
```

After allocation rewriting:

```mlir
%N = arith.constant 1024 : index
%A = arbiter.alloc(%N) : memref<?xi32>
memref.store %v, %A[%i] : memref<?xi32>
arbiter.dealloc %A : memref<?xi32>
```

After lowering to LLVM dialect, schematically:

```mlir
%size = ...  // N * sizeof(i32)
%align = llvm.mlir.constant(64 : i64) : i64
%raw = llvm.call @arbiter_alloc(%size, %align)
       : (i64, i64) -> !llvm.ptr
llvm.call @arbiter_dealloc(%raw)
       : (!llvm.ptr) -> ()
```

In an actual memref lowering path, `arbiter_alloc` returns the underlying buffer pointer, and the lowering must still construct or update the memref descriptor used by later `memref.load` / `memref.store` lowering.

At machine level, later memory accesses are still normal load/store instructions. The placement effect comes from the pointer returned by `arbiter_alloc`.
