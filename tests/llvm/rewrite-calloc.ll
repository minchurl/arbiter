; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-all-rewrite -S %s | FileCheck %s

declare ptr @calloc(i64, i64)
declare void @free(ptr)

define void @main() {
entry:
  %p = call ptr @calloc(i64 4, i64 8)
  call void @free(ptr %p)
  ret void
}

; CHECK-LABEL: define void @main
; CHECK: call ptr @arbiter_calloc_site(i64 4, i64 8, i64 64, i32 1, i32 0)
; CHECK: call void @arbiter_free_maybe(ptr %p)
; CHECK-NOT: call ptr @calloc
; CHECK-DAG: declare ptr @arbiter_calloc_site(i64, i64, i64, i32, i32)
