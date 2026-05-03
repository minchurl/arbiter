// RUN: arbiter-opt --arbiter-mark-candidates %s | FileCheck %s

module {
  func.func @mark(%n: index) {
    // CHECK: memref.alloc{{.*}} {arbiter.candidate, arbiter.target = "remote"} : memref<?xi32>
    %a = memref.alloc(%n) : memref<?xi32>
    memref.dealloc %a : memref<?xi32>
    return
  }
}
