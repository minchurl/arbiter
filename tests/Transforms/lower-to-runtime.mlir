// RUN: arbiter-opt --arbiter-select-objects --arbiter-rewrite-allocations --arbiter-lower-to-runtime %s | FileCheck %s --implicit-check-not=cxl

module {
  func.func @lower(%n: index) {
    %value = arith.constant 7 : i32
    %c0 = arith.constant 0 : index
    %a = memref.alloc(%n) {arbiter.select} : memref<?xi32>
    memref.store %value, %a[%c0] : memref<?xi32>
    memref.dealloc %a : memref<?xi32>
    return
  }

  func.func @lower_static() {
    %a = memref.alloc() : memref<4xi32>
    memref.dealloc %a : memref<4xi32>
    return
  }
}

// CHECK-DAG: llvm.func @arbiter_alloc(i64, i64) -> !llvm.ptr
// CHECK-DAG: llvm.func @arbiter_dealloc(!llvm.ptr)
// CHECK-LABEL: llvm.func @lower
// CHECK: %[[SIZE:[0-9]+]] = llvm.ptrtoint
// CHECK: %[[ALIGN:[0-9]+]] = llvm.mlir.constant(64 : i64) : i64
// CHECK: %[[PTR:[0-9]+]] = llvm.call @arbiter_alloc(%[[SIZE]], %[[ALIGN]]) : (i64, i64) -> !llvm.ptr
// CHECK: llvm.insertvalue %[[PTR]], %{{[0-9]+}}[0]
// CHECK: llvm.insertvalue %[[PTR]], %{{[0-9]+}}[1]
// CHECK: llvm.store
// CHECK: %[[BASE:[0-9]+]] = llvm.extractvalue %{{[0-9]+}}[0]
// CHECK: llvm.call @arbiter_dealloc(%[[BASE]]) : (!llvm.ptr) -> ()
