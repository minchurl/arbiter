// RUN: arbiter-opt --arbiter-select-allocations %s | FileCheck %s

module {
  func.func @select(%n: index) {
    // CHECK: memref.alloc{{.*}} {arbiter.select} : memref<?xi32>
    %a = memref.alloc(%n) : memref<?xi32>
    memref.dealloc %a : memref<?xi32>
    return
  }
}
