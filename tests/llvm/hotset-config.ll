; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-weight-worker-entry=20 -arbiter-hitm-require-escape=0 -arbiter-hitm-require-sync=0 -arbiter-hitm-min-score=20 -arbiter-hitm-seed-limit=1 -arbiter-hotset-expansion=none -S %s | FileCheck %s --check-prefix=WEIGHT
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-require-sync=0 -arbiter-hitm-min-score=4 -arbiter-hitm-seed-limit=5 -arbiter-hotset-expansion=none -S %s | FileCheck %s --check-prefix=GATE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-large-allocation-threshold=100 -arbiter-hitm-require-escape=0 -arbiter-hitm-min-score=4 -arbiter-hitm-seed-limit=3 -arbiter-hotset-expansion=none -S %s | FileCheck %s --check-prefix=SIZE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-include-dynamic-size=1 -arbiter-hitm-min-score=7 -arbiter-hitm-seed-limit=2 -arbiter-hotset-expansion=none -S %s | FileCheck %s --check-prefix=DYNAMIC-ON
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-include-dynamic-size=0 -arbiter-hitm-min-score=7 -arbiter-hitm-seed-limit=2 -arbiter-hotset-expansion=none -S %s | FileCheck %s --check-prefix=DYNAMIC-OFF
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=1 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-max-estimated-bytes=4160 -S %s | FileCheck %s --check-prefix=BYTE-BUDGET
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=1 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-max-members-per-seed=1 -S %s | FileCheck %s --check-prefix=MEMBER-CAP
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hotset-sites -arbiter-hitm-seed-site-ids=1 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-max-estimated-bytes=4160 -disable-output %s | FileCheck %s --check-prefix=REPORT
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hotset-sites -arbiter-hitm-seed-site-ids=6 -arbiter-hotset-expansion=none -arbiter-hotset-dynamic-size-estimate=12345 -disable-output %s | FileCheck %s --check-prefix=DYNAMIC-ESTIMATE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=7 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-include-mmap=0 -S %s | FileCheck %s --check-prefix=MMAP-OFF
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=7 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-include-mmap=1 -S %s | FileCheck %s --check-prefix=MMAP-ON
; RUN: not opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hotset-sites -arbiter-hitm-seed-site-ids=1 -arbiter-hotset-max-estimated-bytes=4095 -disable-output %s 2>&1 | FileCheck %s --check-prefix=INVALID-BYTE-BUDGET

@global_ptr = global ptr null
@counter = global i32 0

declare ptr @malloc(i64)
declare ptr @calloc(i64, i64)
declare ptr @mmap(ptr, i64, i32, i32, i32, i64)
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

define void @mmap_bundle() {
entry:
  %seed = call ptr @malloc(i64 64)
  %field0 = getelementptr i8, ptr %seed, i64 8
  %field1 = getelementptr i8, ptr %seed, i64 16
  %array = call ptr @calloc(i64 4, i64 8)
  store ptr %array, ptr %field0
  %mapping = call ptr @mmap(ptr null, i64 8192, i32 3, i32 32, i32 -1, i64 0)
  store ptr %mapping, ptr %field1
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

; MEMBER-CAP-LABEL: define void @seed_bundle
; MEMBER-CAP: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 1, i32 0)
; MEMBER-CAP: call ptr @arbiter_alloc_site(i64 64, i64 64, i32 2, i32 0)
; MEMBER-CAP: call ptr @malloc(i64 128)

; REPORT: site_id,kind,function,file,line,callee,size_expr,estimated_bytes,score,role,group_id,selected,reasons,member_affinity,member_access_kind,member_access_depth
; REPORT: 2,malloc,seed_bundle,,0,malloc,64,64,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",1,attach,0
; REPORT: 3,malloc,seed_bundle,,0,malloc,128,128,6,rejected,1,no,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function;hotset-rejected:byte-budget",1,attach,0

; DYNAMIC-ESTIMATE: 6,malloc,dynamic_candidate,,0,malloc,%size,12345,7,seed,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function;dynamic-size",0,,-1

; MMAP-OFF-LABEL: define void @mmap_bundle
; MMAP-OFF: call ptr @arbiter_alloc_site(i64 64, i64 64, i32 7, i32 0)
; MMAP-OFF: call ptr @arbiter_calloc_site(i64 4, i64 8, i64 64, i32 8, i32 0)
; MMAP-OFF: call ptr @mmap(ptr null, i64 8192, i32 3, i32 32, i32 -1, i64 0)

; MMAP-ON-LABEL: define void @mmap_bundle
; MMAP-ON: call ptr @arbiter_alloc_site(i64 64, i64 64, i32 7, i32 0)
; MMAP-ON: call ptr @arbiter_calloc_site(i64 4, i64 8, i64 64, i32 8, i32 0)
; MMAP-ON: call ptr @arbiter_mmap_site(i64 8192, i32 3, i32 32, i32 9, i32 0)

; INVALID-BYTE-BUDGET: LLVM ERROR: arbiter hotset config: selected HITM seeds exceed hotset max-estimated-bytes 4095
