// RUN: not arbiter-opt --arbiter-lower-to-runtime %s 2>&1 | FileCheck %s

module {
  func.func @bad_layout() {
    %a = arbiter.alloc() : memref<4xi32, strided<[2], offset: 0>>
    arbiter.dealloc %a : memref<4xi32, strided<[2], offset: 0>>
    return
  }
}

// CHECK: arbiter.alloc lowering only supports identity layout maps
