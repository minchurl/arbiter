; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-adaptive-rewrite -arbiter-hitm-seed-site-ids=1 -S %s | FileCheck %s --check-prefix=ADAPT
; ADAPT: call ptr @arbiter_adaptive_counter()
; ADAPT: exit:
; ADAPT-NEXT: {{.*}}load atomic i64, ptr {{.*}} monotonic, align 8
; ADAPT-NEXT: {{.*}}add i64 {{.*}}, 100
; ADAPT-NEXT: store atomic i64 {{.*}} monotonic, align 8
; ADAPT: call void @arbiter_adaptive_register(i32 2)
; ADAPT-NOT: call void @arbiter_adaptive_register(i32 3)
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-companion-sites -arbiter-hitm-seed-site-ids=1 -disable-output %s | FileCheck %s
; CHECK: seed_id,companion_id,relation,function,access,loop_depth
; CHECK-NEXT: 1,2,same-worker-loop,worker,read,1
; CHECK-NOT: same-worker-loop

@seed = global ptr null
@companion = global ptr null
@outside = global ptr null

declare ptr @malloc(i64)
declare i32 @pthread_create(ptr, ptr, ptr, ptr)

define i32 @main() {
  %a = call ptr @malloc(i64 64)
  store ptr %a, ptr @seed
  %b = call ptr @malloc(i64 4096)
  store ptr %b, ptr @companion
  %c = call ptr @malloc(i64 4096)
  store ptr %c, ptr @outside
  %thread = call i32 @pthread_create(ptr null, ptr null, ptr @worker, ptr null)
  ret i32 0
}

define ptr @worker(ptr %unused) {
entry:
  %s = load ptr, ptr @seed
  %c = load ptr, ptr @companion
  %o = load ptr, ptr @outside
  %before = load volatile i64, ptr %o
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %body ]
  br label %retry
retry:
  %old = atomicrmw add ptr %s, i64 1 monotonic
  %again = icmp eq i64 %old, 0
  br i1 %again, label %retry, label %body
body:
  %address = getelementptr i64, ptr %c, i64 %i
  %value = load volatile i64, ptr %address
  %next = add i64 %i, 1
  %continue = icmp ult i64 %next, 100
  br i1 %continue, label %loop, label %exit
exit:
  ret ptr null
}
