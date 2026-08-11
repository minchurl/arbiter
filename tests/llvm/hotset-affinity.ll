; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hotset-sites -arbiter-hitm-seed-site-ids=2 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-member-max-call-depth=1 -arbiter-hotset-member-max-load-depth=2 -arbiter-hotset-max-members-per-seed=0 -arbiter-hotset-max-sites=32 -disable-output %s | FileCheck %s --check-prefix=REPORT
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=2 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=5 -arbiter-hotset-member-max-call-depth=1 -arbiter-hotset-member-max-load-depth=2 -arbiter-hotset-max-members-per-seed=0 -arbiter-hotset-max-sites=32 -S %s | FileCheck %s --check-prefix=WRITE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=2 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=3 -arbiter-hotset-member-max-call-depth=1 -arbiter-hotset-member-max-load-depth=2 -arbiter-hotset-max-members-per-seed=0 -arbiter-hotset-max-sites=32 -S %s | FileCheck %s --check-prefix=READ
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=2 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=5 -arbiter-hotset-member-max-call-depth=0 -arbiter-hotset-member-max-load-depth=2 -arbiter-hotset-max-members-per-seed=0 -arbiter-hotset-max-sites=32 -S %s | FileCheck %s --check-prefix=CALL-DEPTH-ZERO
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=2 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=5 -arbiter-hotset-member-max-call-depth=1 -arbiter-hotset-member-max-load-depth=1 -arbiter-hotset-max-members-per-seed=0 -arbiter-hotset-max-sites=32 -S %s | FileCheck %s --check-prefix=LOAD-DEPTH-ONE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=2 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-member-max-call-depth=1 -arbiter-hotset-member-max-load-depth=2 -arbiter-hotset-max-members-per-seed=1 -arbiter-hotset-max-sites=32 -S %s | FileCheck %s --check-prefix=RANK
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hotset-sites -arbiter-hitm-seed-site-ids=13,14 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-member-max-call-depth=1 -arbiter-hotset-member-max-load-depth=2 -arbiter-hotset-max-members-per-seed=0 -arbiter-hotset-max-sites=32 -disable-output %s | FileCheck %s --check-prefix=OVERLAP

@global_ptr = global ptr null
@counter = global i32 0

declare ptr @malloc(i64)
declare void @unknown_use(ptr)
declare void @readonly_use(ptr readonly)
declare void @writeonly_use(ptr writeonly)

define void @direct_write(ptr %member) {
entry:
  store i32 7, ptr %member
  ret void
}

define void @receiver_with_temporary(ptr %owner) {
entry:
  %temporary = call ptr @malloc(i64 80)
  call void @unknown_use(ptr %temporary)
  ret void
}

define void @seed_function() {
entry:
  %seed = call ptr @malloc(i64 4096)

  %attach.slot = getelementptr i8, ptr %seed, i64 8
  %attach = call ptr @malloc(i64 16)
  store ptr %attach, ptr %attach.slot

  %pointer.slot = getelementptr i8, ptr %seed, i64 16
  %pointer = call ptr @malloc(i64 24)
  store ptr %pointer, ptr %pointer.slot
  %pointer.loaded = load ptr, ptr %pointer.slot
  %pointer.null = icmp eq ptr %pointer.loaded, null

  %read.slot = getelementptr i8, ptr %seed, i64 24
  %read = call ptr @malloc(i64 32)
  store ptr %read, ptr %read.slot
  %read.loaded = load ptr, ptr %read.slot
  %read.value0 = load i32, ptr %read.loaded
  %read.value1 = load i32, ptr %read.loaded

  %readonly.slot = getelementptr i8, ptr %seed, i64 32
  %readonly = call ptr @malloc(i64 40)
  store ptr %readonly, ptr %readonly.slot
  %readonly.loaded = load ptr, ptr %readonly.slot
  call void @readonly_use(ptr %readonly.loaded)

  %write.slot = getelementptr i8, ptr %seed, i64 40
  %write = call ptr @malloc(i64 48)
  store ptr %write, ptr %write.slot
  %write.loaded = load ptr, ptr %write.slot
  store i32 9, ptr %write.loaded

  %atomic.slot = getelementptr i8, ptr %seed, i64 48
  %atomic = call ptr @malloc(i64 56)
  store ptr %atomic, ptr %atomic.slot
  %atomic.loaded = load ptr, ptr %atomic.slot
  %old = atomicrmw add ptr %atomic.loaded, i32 1 seq_cst

  %mutating.slot = getelementptr i8, ptr %seed, i64 56
  %mutating = call ptr @malloc(i64 64)
  store ptr %mutating, ptr %mutating.slot
  %mutating.loaded = load ptr, ptr %mutating.slot
  call void @writeonly_use(ptr %mutating.loaded)

  %unknown.slot = getelementptr i8, ptr %seed, i64 64
  %unknown = call ptr @malloc(i64 72)
  store ptr %unknown, ptr %unknown.slot
  %unknown.loaded = load ptr, ptr %unknown.slot
  call void @unknown_use(ptr %unknown.loaded)

  %entries.slot = getelementptr i8, ptr %seed, i64 72
  %entries = call ptr @malloc(i64 128)
  store ptr %entries, ptr %entries.slot
  %entries.loaded = load ptr, ptr %entries.slot
  %entry.slot = getelementptr ptr, ptr %entries.loaded, i64 3
  %entry.member = call ptr @malloc(i64 96)
  store ptr %entry.member, ptr %entry.slot
  %entry.member.loaded = load ptr, ptr %entry.slot
  call void @direct_write(ptr %entry.member.loaded)

  call void @receiver_with_temporary(ptr %seed)
  store ptr %seed, ptr @global_ptr
  %seed.old = atomicrmw add ptr @counter, i32 1 seq_cst
  ret void
}

define void @overlap_seed_function() {
entry:
  %seed.a = call ptr @malloc(i64 4096)
  %seed.b = call ptr @malloc(i64 4096)
  %member = call ptr @malloc(i64 32)

  %seed.a.slot = getelementptr i8, ptr %seed.a, i64 8
  store ptr %member, ptr %seed.a.slot
  %seed.a.member = load ptr, ptr %seed.a.slot
  call void @readonly_use(ptr %seed.a.member)

  %seed.b.slot = getelementptr i8, ptr %seed.b, i64 8
  store ptr %member, ptr %seed.b.slot
  %seed.b.member = load ptr, ptr %seed.b.slot
  store i32 1, ptr %seed.b.member

  store ptr %seed.a, ptr @global_ptr
  store ptr %seed.b, ptr @global_ptr
  %old = atomicrmw add ptr @counter, i32 1 seq_cst
  ret void
}

; REPORT: site_id,kind,function,file,line,callee,size_expr,estimated_bytes,score,role,group_id,selected,reasons,member_affinity,member_access_kind,member_access_depth
; REPORT: 1,malloc,receiver_with_temporary,,0,malloc,80,80,2,rejected,0,no,"escapes-call;no-sync-mutable;hotset-rejected:outside-access-closure",0,,-1
; REPORT: 3,malloc,seed_function,,0,malloc,16,16,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",1,attach,0
; REPORT: 4,malloc,seed_function,,0,malloc,24,24,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",2,pointer,1
; REPORT: 5,malloc,seed_function,,0,malloc,32,32,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",3,read,1
; REPORT: 6,malloc,seed_function,,0,malloc,40,40,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",3,read,1
; REPORT: 7,malloc,seed_function,,0,malloc,48,48,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",5,write,1
; REPORT: 8,malloc,seed_function,,0,malloc,56,56,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",5,write,1
; REPORT: 9,malloc,seed_function,,0,malloc,64,64,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",5,write,1
; REPORT: 10,malloc,seed_function,,0,malloc,72,72,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",2,pointer,1
; REPORT: 11,malloc,seed_function,,0,malloc,128,128,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",5,write,1
; REPORT: 12,malloc,seed_function,,0,malloc,96,96,6,member,1,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",5,write,3

; WRITE-LABEL: define void @seed_function
; WRITE: call ptr @malloc(i64 16)
; WRITE: call ptr @malloc(i64 24)
; WRITE: call ptr @malloc(i64 32)
; WRITE: call ptr @malloc(i64 40)
; WRITE: call ptr @arbiter_alloc_site(i64 48, i64 64, i32 7, i32 0)
; WRITE: call ptr @arbiter_alloc_site(i64 56, i64 64, i32 8, i32 0)
; WRITE: call ptr @arbiter_alloc_site(i64 64, i64 64, i32 9, i32 0)
; WRITE: call ptr @malloc(i64 72)
; WRITE: call ptr @arbiter_alloc_site(i64 128, i64 64, i32 11, i32 0)
; WRITE: call ptr @arbiter_alloc_site(i64 96, i64 64, i32 12, i32 0)

; READ-LABEL: define void @seed_function
; READ: call ptr @malloc(i64 16)
; READ: call ptr @malloc(i64 24)
; READ: call ptr @arbiter_alloc_site(i64 32, i64 64, i32 5, i32 0)
; READ: call ptr @arbiter_alloc_site(i64 40, i64 64, i32 6, i32 0)
; READ: call ptr @arbiter_alloc_site(i64 48, i64 64, i32 7, i32 0)
; READ: call ptr @arbiter_alloc_site(i64 56, i64 64, i32 8, i32 0)
; READ: call ptr @arbiter_alloc_site(i64 64, i64 64, i32 9, i32 0)
; READ: call ptr @malloc(i64 72)
; READ: call ptr @arbiter_alloc_site(i64 128, i64 64, i32 11, i32 0)
; READ: call ptr @arbiter_alloc_site(i64 96, i64 64, i32 12, i32 0)

; CALL-DEPTH-ZERO-LABEL: define void @seed_function
; CALL-DEPTH-ZERO: call ptr @malloc(i64 96)

; LOAD-DEPTH-ONE-LABEL: define void @seed_function
; LOAD-DEPTH-ONE: call ptr @malloc(i64 96)

; RANK-LABEL: define void @seed_function
; RANK: call ptr @malloc(i64 16)
; RANK: call ptr @arbiter_alloc_site(i64 48, i64 64, i32 7, i32 0)

; OVERLAP: 15,malloc,overlap_seed_function,,0,malloc,32,32,6,member,2,yes,"escapes-store;sync-atomic-rmw-or-cmpxchg-same-function",5,write,1
