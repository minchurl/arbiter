; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-shared-mutable-sites -disable-output %s | FileCheck %s

@global_ptr = global ptr null
@counter = global i32 0

declare ptr @malloc(i64)
declare void @free(ptr)
declare void @consume(ptr)
declare i32 @pthread_create(ptr, ptr, ptr, ptr)

define void @escaped_atomic() {
entry:
  %p = call ptr @malloc(i64 4096)
  store ptr %p, ptr @global_ptr
  %old = atomicrmw add ptr @counter, i32 1 seq_cst
  ret void
}

define void @escaped_inline_asm(i64 %n) {
entry:
  %p = call ptr @malloc(i64 %n)
  store ptr %p, ptr @global_ptr
  call void asm sideeffect "lock; cmpxchg", ""()
  ret void
}

define void @local_temp_atomic() {
entry:
  %p = call ptr @malloc(i64 4096)
  %old = atomicrmw add ptr @counter, i32 1 seq_cst
  call void @free(ptr %p)
  ret void
}

define void @escaped_no_sync() {
entry:
  %p = call ptr @malloc(i64 4096)
  store ptr %p, ptr @global_ptr
  ret void
}

define ptr @worker(ptr %arg) {
entry:
  %p = call ptr @malloc(i64 4096)
  store ptr %p, ptr @global_ptr
  store atomic i32 1, ptr @counter seq_cst, align 4
  ret ptr null
}

define void @spawn() {
entry:
  %r = call i32 @pthread_create(ptr null, ptr null, ptr @worker, ptr null)
  ret void
}

; CHECK: site_id,kind,function,file,line,callee,size_expr,score,selected,reasons
; CHECK: 1,malloc,escaped_atomic,,0,malloc,4096,7,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function;large-allocation"
; CHECK: 2,malloc,escaped_inline_asm,,0,malloc,%n,6,yes,"escapes-store;sync-inline-asm-same-function;dynamic-size"
; CHECK: 3,malloc,local_temp_atomic,,0,malloc,4096,4,no,"sync-atomic-rmw-or-cmpxchg-same-function;large-allocation;no-escape"
; CHECK: 4,free,local_temp_atomic,,0,free,,0,no,not-heap-allocation
; CHECK: 5,malloc,escaped_no_sync,,0,malloc,4096,4,no,"escapes-store;large-allocation;no-sync-mutable"
; CHECK: 6,malloc,worker,,0,malloc,4096,9,yes,"escapes-store;sync-atomic-or-volatile-store-same-function;pthread-worker-entry;large-allocation"
