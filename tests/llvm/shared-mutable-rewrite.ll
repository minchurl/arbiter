; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-shared-mutable-rewrite -S %s | FileCheck %s
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-shared-mutable-rewrite -arbiter-shared-mutable-min-score=9 -S %s | FileCheck %s --check-prefix=THRESHOLD

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

; CHECK-LABEL: define void @escaped_atomic
; CHECK: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 1, i32 0)
; CHECK-LABEL: define void @escaped_inline_asm
; CHECK: call ptr @arbiter_alloc_site(i64 %n, i64 64, i32 2, i32 0)
; CHECK-LABEL: define void @local_temp_atomic
; CHECK: call ptr @malloc(i64 4096)
; CHECK: call void @arbiter_free_maybe(ptr %p)
; CHECK-LABEL: define void @escaped_no_sync
; CHECK: call ptr @malloc(i64 4096)
; CHECK-LABEL: define ptr @worker
; CHECK: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 6, i32 0)
; CHECK-DAG: declare ptr @arbiter_alloc_site(i64, i64, i32, i32)
; CHECK-DAG: declare void @arbiter_free_maybe(ptr)

; THRESHOLD-LABEL: define void @escaped_atomic
; THRESHOLD: call ptr @malloc(i64 4096)
; THRESHOLD-LABEL: define void @escaped_inline_asm
; THRESHOLD: call ptr @malloc(i64 %n)
; THRESHOLD-LABEL: define ptr @worker
; THRESHOLD: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 6, i32 0)
