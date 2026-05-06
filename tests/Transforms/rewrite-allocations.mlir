// RUN: arbiter-opt --arbiter-select-objects --arbiter-rewrite-allocations %s | FileCheck %s

module {
  func.func @rewrite(%n: index) {
    // CHECK: arbiter.alloc(%{{.*}}) : memref<?xi32>
    // CHECK: arbiter.dealloc %{{.*}} : memref<?xi32>
    %a = memref.alloc(%n) : memref<?xi32>
    memref.dealloc %a : memref<?xi32>
    return
  }
}
