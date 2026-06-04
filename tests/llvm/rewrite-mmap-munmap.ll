; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-all-rewrite -S %s | FileCheck %s

declare ptr @mmap(ptr, i64, i32, i32, i32, i64)
declare i32 @munmap(ptr, i64)

define i32 @main() {
entry:
  %p = call ptr @mmap(ptr null, i64 4096, i32 3, i32 34, i32 -1, i64 0)
  %r = call i32 @munmap(ptr %p, i64 4096)
  ret i32 %r
}

; CHECK-LABEL: define i32 @main
; CHECK: call ptr @arbiter_mmap_site(i64 4096, i32 3, i32 34, i32 1, i32 0)
; CHECK: call i32 @arbiter_munmap_maybe(ptr %p, i64 4096)
; CHECK-NOT: call ptr @mmap
; CHECK-NOT: call i32 @munmap
; CHECK-DAG: declare ptr @arbiter_mmap_site(i64, i32, i32, i32, i32)
; CHECK-DAG: declare i32 @arbiter_munmap_maybe(ptr, i64)
