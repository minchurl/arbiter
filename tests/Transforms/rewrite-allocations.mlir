// RUN: arbiter-opt --arbiter-mark-candidates --arbiter-rewrite-allocations %s | FileCheck %s

module {
  func.func @rewrite(%n: index) {
    // CHECK: arbiter.alloc(%{{.*}}) {target = "remote"} : memref<?xi32>
    // CHECK: arbiter.dealloc %{{.*}} {target = "remote"} : memref<?xi32>
    %a = memref.alloc(%n) : memref<?xi32>
    memref.dealloc %a : memref<?xi32>
    return
  }
}
