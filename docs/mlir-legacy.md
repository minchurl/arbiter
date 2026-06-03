# MLIR Legacy Path

This document describes Arbiter's retained MLIR precision/reference path. It is
legacy code and is not used by the current LLVM-only benchmark workflow.

## Overview

The MLIR path models Arbiter as a compiler-assisted placement system for
coherence-sensitive allocation-backed memory objects in tiered memory
environments.

It identifies allocation-backed objects whose performance may be dominated by
cache-coherence activity rather than raw memory access latency, and places
selected objects on an alternative memory node such as CXL memory or a remote
NUMA node.

The first target is allocation-time placement based on static compiler
analysis. Arbiter does not move objects after the program starts running.

## Compiler Design

The MLIR path separates object selection from allocation rewriting.

### Object Selection

Object selection decides which allocation-backed memory objects should be
placed on the target memory node. This decision is made statically during
compilation.

The first version may select all eligible allocation-backed objects to validate
the rewrite and runtime placement path. Later versions can use more selective
static policies:

- manually annotated objects
- static write-intensity analysis
- static sharing or escape analysis
- parallel-region-aware analysis
- cache-line and sub-object layout hints
- static object scoring based on coherence-sensitivity likelihood

All versions produce the same output: a selected object or an object-level
placement decision.

### Allocation Rewriting

Allocation rewriting consumes the selection result and rewrites selected
allocation/deallocation sites into Arbiter dialect operations.

```text
memref.alloc
  -> arbiter.alloc
  -> arbiter_alloc(...)

memref.dealloc
  -> arbiter.dealloc
  -> arbiter_dealloc(...)
```

`arbiter.alloc` is backend-independent. It can be lowered to a node-backed
allocator in the current setup, and later to a CXL-backed allocator if real CXL
memory is available.

The compiler does not generate special CXL load/store instructions. CXL memory
and NUMA memory are accessed through normal CPU load/store instructions after
the object has been allocated on the target node.

## Input Definition

The MLIR tool takes MLIR as input:

```text
arbiter-opt input.mlir -> transformed.mlir
```

The path targets memref-level MLIR because allocation objects, stores, loops,
and parallel regions are still visible enough for static analysis.

C/C++ support would require a frontend that emits suitable MLIR. If a frontend
lowers everything to LLVM-dialect malloc calls before Arbiter runs, the core
analysis input is already too low-level for this path.

## Input IR Strategy

Object selection should run at the highest MLIR level that still exposes
allocation objects and structured memory accesses.

The prototype assumes memref-level allocation objects:

```text
memref.alloc
  -> arbiter.select
  -> arbiter.alloc
  -> arbiter_alloc(...)

memref.dealloc
  -> arbiter.dealloc
  -> arbiter_dealloc(...)
```

This level is useful because object identity and memory accesses are explicit.
It also makes it easier to reason about stores inside loops, parallel regions,
and other structured control-flow constructs.

## Placement Granularity

The MLIR path uses allocation-object granularity because `memref.alloc` gives
Arbiter a clear compiler-visible object boundary.

This is a known limitation. A large allocation can contain cold regions,
read-mostly regions, and coherence-heavy regions. Page-level or sub-object
placement is future work.

## Example Transformation

The prototype changes allocation and deallocation operations only. Memory
accesses remain ordinary `memref.load` / `memref.store` operations and later
become normal CPU load/store instructions.

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

At machine level, later memory accesses are still normal load/store
instructions. The placement effect comes from the pointer returned by
`arbiter_alloc`.
