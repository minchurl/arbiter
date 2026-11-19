; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-adaptive-rewrite -arbiter-hitm-seed-site-ids=1 -S %s | FileCheck %s
; CHECK-NOT: call ptr @arbiter_adaptive_counter
; CHECK: call void @arbiter_adaptive_observe_range(ptr @unrelated_name, i64 2, i64 64)

@seed = global ptr null
@companion = global ptr null
%Slot = type { i64, [56 x i8] }
@unrelated_name = global [2 x %Slot] [%Slot { i64 0, [56 x i8] undef }, %Slot { i64 0, [56 x i8] undef }]
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
  %id = ptrtoint ptr %unused to i64
  %counter = getelementptr [2 x %Slot], ptr @unrelated_name, i64 0, i64 %id
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
  store atomic i64 %published, ptr %counter monotonic, align 8
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
