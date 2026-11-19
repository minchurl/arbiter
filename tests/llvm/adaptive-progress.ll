; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-adaptive-rewrite -arbiter-hitm-seed-site-ids=1 -S %s | FileCheck %s
; RUN: sed 's/%published = add i64 %first, %i/%published = add i64 0, %i/' %s | opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-adaptive-rewrite -arbiter-hitm-seed-site-ids=1 -S - | FileCheck %s --check-prefix=RESET
; RUN: sed 's/%totalnext = add i64 %total, 4/%totalnext = add i64 %total, 3/' %s | opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-adaptive-rewrite -arbiter-hitm-seed-site-ids=1 -S - | FileCheck %s --check-prefix=RESET
; CHECK-NOT: call ptr @arbiter_adaptive_counter
; CHECK: call void @arbiter_adaptive_register(i32 2)
; CHECK: call void @arbiter_adaptive_observe_range(ptr @unrelated_name, i64 1, i64 8)
; RESET: call ptr @arbiter_adaptive_counter()
; RESET-NOT: arbiter_adaptive_observe_range

@seed = global ptr null
@companion = global ptr null
@unrelated_name = global i64 0
@stop = global i1 false
declare ptr @malloc(i64)
declare i32 @pthread_create(ptr, ptr, ptr, ptr)
define i32 @main() {
  %s = call ptr @malloc(i64 64)
  store ptr %s, ptr @seed
  %c = call ptr @malloc(i64 4096)
  store ptr %c, ptr @companion
  %thread = call i32 @pthread_create(ptr null, ptr null, ptr @worker, ptr null)
  ret i32 0
}
define ptr @worker(ptr %unused) {
entry:
  %s = load ptr, ptr @seed
  %c = load ptr, ptr @companion
  br label %outer
outer:
  %total = phi i64 [0, %entry], [%totalnext, %after]
  %first = add i64 %total, 1
  br label %inner
inner:
  %i = phi i64 [0, %outer], [%next, %inner]
  %old = atomicrmw add ptr %s, i64 1 monotonic
  %read = load volatile i64, ptr %c
  %published = add i64 %first, %i
  store atomic i64 %published, ptr @unrelated_name monotonic, align 8
  %next = add i64 %i, 1
  %more = icmp ult i64 %next, 4
  br i1 %more, label %inner, label %after
after:
  %totalnext = add i64 %total, 4
  %done = load volatile i1, ptr @stop
  br i1 %done, label %exit, label %outer
exit:
  ret ptr null
}
