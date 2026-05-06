// RUN: arbiter-opt --arbiter-select-objects --arbiter-rewrite-allocations %s | FileCheck %s

module {
  func.func @rewrite(%n: index, %value: i32) {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    // CHECK-LABEL: func.func @rewrite
    // CHECK: %[[SELECTED:.*]] = arbiter.alloc(%{{.*}}) : memref<?xi32>
    %selected = memref.alloc(%n) : memref<?xi32>
    // CHECK: %[[SERIAL:.*]] = memref.alloc(%{{.*}}) : memref<?xi32>
    %serial = memref.alloc(%n) : memref<?xi32>
    scf.parallel (%i) = (%c0) to (%n) step (%c1) {
      memref.store %value, %selected[%i] : memref<?xi32>
      scf.reduce
    }
    memref.store %value, %serial[%c0] : memref<?xi32>
    // CHECK: arbiter.dealloc %[[SELECTED]] : memref<?xi32>
    memref.dealloc %selected : memref<?xi32>
    // CHECK: memref.dealloc %[[SERIAL]] : memref<?xi32>
    memref.dealloc %serial : memref<?xi32>
    return
  }
}
