; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-weight-worker-entry=20 -arbiter-hitm-require-escape=0 -arbiter-hitm-require-sync=0 -arbiter-hitm-min-score=20 -arbiter-hitm-seed-limit=1 -S %s | FileCheck %s --check-prefix=WEIGHT
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-require-sync=0 -arbiter-hitm-min-score=4 -arbiter-hitm-seed-limit=5 -S %s | FileCheck %s --check-prefix=GATE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-large-allocation-threshold=100 -arbiter-hitm-require-escape=0 -arbiter-hitm-min-score=4 -arbiter-hitm-seed-limit=3 -S %s | FileCheck %s --check-prefix=SIZE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-include-dynamic-size=1 -arbiter-hitm-min-score=7 -arbiter-hitm-seed-limit=2 -S %s | FileCheck %s --check-prefix=DYNAMIC-ON
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-include-dynamic-size=0 -arbiter-hitm-min-score=7 -arbiter-hitm-seed-limit=2 -S %s | FileCheck %s --check-prefix=DYNAMIC-OFF
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=1,2 -arbiter-hotset-max-estimated-bytes=4160 -S %s | FileCheck %s --check-prefix=BYTE-BUDGET
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hotset-sites -arbiter-hitm-seed-site-ids=1,2 -arbiter-hotset-max-estimated-bytes=4160 -disable-output %s | FileCheck %s --check-prefix=REPORT
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hotset-sites -arbiter-hitm-seed-site-ids=6 -arbiter-hotset-dynamic-size-estimate=12345 -disable-output %s | FileCheck %s --check-prefix=DYNAMIC-ESTIMATE
; RUN: not opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hotset-sites -arbiter-hitm-seed-site-ids=1 -arbiter-hotset-max-estimated-bytes=4095 -disable-output %s 2>&1 | FileCheck %s --check-prefix=INVALID-BYTE-BUDGET

@global_ptr = global ptr null
@counter = global i32 0

declare ptr @malloc(i64)
declare ptr @calloc(i64, i64)
declare i32 @pthread_create(ptr, ptr, ptr, ptr)

define void @seed_bundle() {
entry:
  %seed = call ptr @malloc(i64 4096)
  store ptr %seed, ptr @global_ptr
  %old = atomicrmw add ptr @counter, i32 1 seq_cst
  %field0 = getelementptr i8, ptr %seed, i64 8
  %field1 = getelementptr i8, ptr %seed, i64 16
  %member0 = call ptr @malloc(i64 64)
  store ptr %member0, ptr %field0
  %member1 = call ptr @malloc(i64 128)
  store ptr %member1, ptr %field1
  ret void
}

define void @escaped_without_sync() {
entry:
  %allocation = call ptr @malloc(i64 4096)
  store ptr %allocation, ptr @global_ptr
  ret void
}

define ptr @worker_a(ptr %arg) {
entry:
  %allocation = call ptr @malloc(i64 32)
  ret ptr null
}

define void @dynamic_candidate(i64 %size) {
entry:
  %allocation = call ptr @malloc(i64 %size)
  store ptr %allocation, ptr @global_ptr
  %old = atomicrmw add ptr @counter, i32 1 seq_cst
  ret void
}

define void @spawn() {
entry:
  %worker = call i32 @pthread_create(ptr null, ptr null, ptr @worker_a, ptr null)
  ret void
}

; WEIGHT-LABEL: define void @seed_bundle
; WEIGHT: call ptr @malloc(i64 4096)
; WEIGHT-LABEL: define ptr @worker_a
; WEIGHT: call ptr @arbiter_alloc_site(i64 32, i64 64, i32 5, i32 0)

; GATE-LABEL: define void @escaped_without_sync
; GATE: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 4, i32 0)

; SIZE-LABEL: define void @seed_bundle
; SIZE: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 1, i32 0)
; SIZE: call ptr @malloc(i64 64)
; SIZE: call ptr @arbiter_alloc_site(i64 128, i64 64, i32 3, i32 0)

; DYNAMIC-ON-LABEL: define void @dynamic_candidate
; DYNAMIC-ON: call ptr @arbiter_alloc_site(i64 %size, i64 64, i32 6, i32 0)

; DYNAMIC-OFF-LABEL: define void @dynamic_candidate
; DYNAMIC-OFF: call ptr @malloc(i64 %size)

; BYTE-BUDGET-LABEL: define void @seed_bundle
; BYTE-BUDGET: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 1, i32 0)
; BYTE-BUDGET: call ptr @arbiter_alloc_site(i64 64, i64 64, i32 2, i32 0)
; BYTE-BUDGET: call ptr @malloc(i64 128)

; REPORT: site_id,kind,function,file,line,callee,size_expr,estimated_bytes,score,role,group_id,selected,reasons
; REPORT: 1,malloc,seed_bundle,,0,malloc,4096,4096,7,seed,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function;large-allocation"
; REPORT: 2,malloc,seed_bundle,,0,malloc,64,64,6,seed,2,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function"

; DYNAMIC-ESTIMATE: 6,malloc,dynamic_candidate,,0,malloc,%size,12345,7,seed,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function;dynamic-size"

; INVALID-BYTE-BUDGET: LLVM ERROR: arbiter hotset config: selected HITM seeds exceed hotset max-estimated-bytes 4095
