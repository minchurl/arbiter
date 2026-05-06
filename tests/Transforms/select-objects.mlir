// RUN: arbiter-opt --arbiter-select-objects %s | FileCheck %s

module {
  func.func @select_parallel_store(%n: index, %value: i32) {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    // CHECK-LABEL: func.func @select_parallel_store
    // CHECK: memref.alloc{{.*}} {arbiter.select} : memref<?xi32>
    %a = memref.alloc(%n) : memref<?xi32>
    scf.parallel (%i) = (%c0) to (%n) step (%c1) {
      memref.store %value, %a[%i] : memref<?xi32>
      scf.reduce
    }
    memref.dealloc %a : memref<?xi32>
    return
  }

  func.func @skip_parallel_load_only(%n: index) {
    %c0 = arith.constant 0 : index
    %c1 = arith.constant 1 : index
    // CHECK-LABEL: func.func @skip_parallel_load_only
    // CHECK-NOT: arbiter.select
    %a = memref.alloc(%n) : memref<?xi32>
    scf.parallel (%i) = (%c0) to (%n) step (%c1) {
      %value = memref.load %a[%i] : memref<?xi32>
      scf.reduce
    }
    memref.dealloc %a : memref<?xi32>
    // CHECK: return
    return
  }

  func.func @skip_serial_store(%n: index, %value: i32) {
    %c0 = arith.constant 0 : index
    // CHECK-LABEL: func.func @skip_serial_store
    // CHECK-NOT: arbiter.select
    %a = memref.alloc(%n) : memref<?xi32>
    memref.store %value, %a[%c0] : memref<?xi32>
    memref.dealloc %a : memref<?xi32>
    // CHECK: return
    return
  }
}
