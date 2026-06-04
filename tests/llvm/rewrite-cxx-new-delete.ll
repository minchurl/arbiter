; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-all-rewrite -S %s | FileCheck %s

declare ptr @_Znwm(i64)
declare void @_ZdlPv(ptr)

define void @main() {
entry:
  %p = call ptr @_Znwm(i64 32)
  call void @_ZdlPv(ptr %p)
  ret void
}

; CHECK-LABEL: define void @main
; CHECK: call ptr @arbiter_alloc_site(i64 32, i64 64, i32 1, i32 0)
; CHECK: call void @arbiter_cxx_delete_maybe(ptr %p)
; CHECK-NOT: call ptr @_Znwm
; CHECK-NOT: call void @_ZdlPv
; CHECK-DAG: declare ptr @arbiter_alloc_site(i64, i64, i32, i32)
; CHECK-DAG: declare void @arbiter_cxx_delete_maybe(ptr)
