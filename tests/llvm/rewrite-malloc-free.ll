; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-all-rewrite -S %s | FileCheck %s

declare ptr @malloc(i64)
declare void @free(ptr)

define void @main() {
entry:
  %p = call ptr @malloc(i64 16)
  call void @free(ptr %p)
  ret void
}

; CHECK-LABEL: define void @main
; CHECK: call ptr @arbiter_alloc_site(i64 16, i64 64, i32 1, i32 0)
; CHECK: call void @arbiter_free_maybe(ptr %p)
; CHECK-NOT: call ptr @malloc
; CHECK-NOT: call void @free
; CHECK-DAG: declare ptr @arbiter_alloc_site(i64, i64, i32, i32)
; CHECK-DAG: declare void @arbiter_free_maybe(ptr)
