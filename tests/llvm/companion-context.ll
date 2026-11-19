; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-companion-sites -arbiter-hitm-seed-site-ids=1 -disable-output %s | FileCheck %s
; CHECK: seed_id,companion_id,relation,function,access,loop_depth
; CHECK-NEXT: 1,2,same-worker-loop,known,read-write,1
; CHECK-NEXT: 1,2,same-worker-loop,split,read-write,1
; CHECK-NOT: same-worker-loop

@seed = global ptr null
@companion = global ptr null
declare ptr @malloc(i64)
declare ptr @unknown()
declare i32 @pthread_create(ptr, ptr, ptr, ptr)
define i32 @main() {
  %s = call ptr @malloc(i64 64)
  store ptr %s, ptr @seed
  %c = call ptr @malloc(i64 64)
  store ptr %c, ptr @companion
  %thread = call i32 @pthread_create(ptr null, ptr null, ptr @worker, ptr null)
  ret i32 0
}
define ptr @worker(ptr %unused) {
  %s = load ptr, ptr @seed
  %c = load ptr, ptr @companion
  %u = call ptr @unknown()
  call void @ambiguous(ptr %s, ptr %c)
  call void @ambiguous(ptr %s, ptr %u)
  call void @known(ptr %s, ptr %c)
  call void @split(ptr %s, ptr %c)
  ret ptr null
}
define void @ambiguous(ptr %s, ptr %c) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %old = atomicrmw add ptr %s, i64 1 monotonic
  %read = load volatile i64, ptr %c
  %next = add i64 %i, 1
  %continue = icmp ult i64 %next, 100
  br i1 %continue, label %loop, label %exit
exit:
  ret void
}
define void @known(ptr %s, ptr %c) {
entry:
  br label %loop
loop:
  %i = phi i64 [ 0, %entry ], [ %next, %loop ]
  %old = atomicrmw add ptr %s, i64 1 monotonic
  %other = atomicrmw add ptr %c, i64 1 monotonic
  %next = add i64 %i, 1
  %continue = icmp ult i64 %next, 100
  br i1 %continue, label %loop, label %exit
exit:
  ret void
}

; Two equally deep common loops must merge access kinds deterministically.
define void @split(ptr %s, ptr %c) {
entry:
  br label %readloop
readloop:
  %i = phi i64 [ 0, %entry ], [ %next, %readloop ]
  %old = atomicrmw add ptr %s, i64 1 monotonic
  %read = load volatile i64, ptr %c
  %next = add i64 %i, 1
  %continue = icmp ult i64 %next, 100
  br i1 %continue, label %readloop, label %between
between:
  br label %writeloop
writeloop:
  %j = phi i64 [ 0, %between ], [ %nextj, %writeloop ]
  %oldj = atomicrmw add ptr %s, i64 1 monotonic
  store volatile i64 %j, ptr %c
  %nextj = add i64 %j, 1
  %continuej = icmp ult i64 %nextj, 100
  br i1 %continuej, label %writeloop, label %exit
exit:
  ret void
}
