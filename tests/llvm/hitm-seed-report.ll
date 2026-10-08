; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hitm-seed-sites -arbiter-hitm-seed-site-ids=2,5 -disable-output %s | FileCheck %s
; RUN: not opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hitm-seed-sites -arbiter-hitm-seed-site-ids=999 -disable-output %s 2>&1 | FileCheck %s --check-prefix=INVALID-SEED

@global_ptr = global ptr null
@counter = global i32 0

declare ptr @malloc(i64)
declare void @consume(ptr)

define ptr @receiver(ptr %owner) {
entry:
  %member = call ptr @malloc(i64 96)
  ret ptr %member
}

define void @seed_function() {
entry:
  %seed = call ptr @malloc(i64 4096)
  %field = getelementptr i8, ptr %seed, i64 8
  %owned = call ptr @malloc(i64 32)
  store ptr %owned, ptr %field
  %unrelated = call ptr @malloc(i64 48)
  call void @consume(ptr %unrelated)
  %member = call ptr @receiver(ptr %seed)
  store ptr %seed, ptr @global_ptr
  %old = atomicrmw add ptr @counter, i32 1 seq_cst
  ret void
}

define void @second_seed_function() {
entry:
  %seed = call ptr @malloc(i64 4096)
  %member = call ptr @receiver(ptr %seed)
  store ptr %seed, ptr @global_ptr
  %old = atomicrmw add ptr @counter, i32 1 seq_cst
  ret void
}

; CHECK: site_id,kind,function,file,line,callee,size_expr,estimated_bytes,score,role,group_id,selected,reasons
; CHECK-NEXT: 1,malloc,receiver,,0,malloc,96,96,3,rejected,0,no,"escapes-return;no-sync-mutable"
; CHECK-NEXT: 2,malloc,seed_function,,0,malloc,4096,4096,9,seed,1,yes,"escapes-store;escapes-call;sync-atomic-rmw-or-cmpxchg-same-function;large-allocation"
; CHECK-NEXT: 3,malloc,seed_function,,0,malloc,32,32,6,rejected,0,no,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function"
; CHECK-NEXT: 4,malloc,seed_function,,0,malloc,48,48,5,rejected,0,no,"escapes-call;sync-atomic-rmw-or-cmpxchg-same-function"
; CHECK-NEXT: 5,malloc,second_seed_function,,0,malloc,4096,4096,9,seed,2,yes,"escapes-store;escapes-call;sync-atomic-rmw-or-cmpxchg-same-function;large-allocation"

; INVALID-SEED: LLVM ERROR: arbiter hitm-seed config: explicit HITM seed site 999 does not exist
