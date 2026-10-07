; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=4 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -S %s | FileCheck %s --check-prefix=USE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=4 -arbiter-hotset-expansion=none -S %s | FileCheck %s --check-prefix=NONE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=4 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-max-members-per-seed=2 -S %s | FileCheck %s --check-prefix=MEMBER-CAP
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=4 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -arbiter-hotset-max-sites=2 -S %s | FileCheck %s --check-prefix=MAX-SITES
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hotset-rewrite -arbiter-hitm-seed-site-ids=4,7 -arbiter-hotset-expansion=use -arbiter-hotset-member-min-affinity=1 -S %s | FileCheck %s --check-prefix=OVERLAP

@global_ptr = global ptr null
@counter = global i32 0

declare ptr @malloc(i64)
declare void @consume(ptr)

define ptr @receiver(ptr %owner) {
entry:
  %member = call ptr @malloc(i64 96)
  ret ptr %member
}

define ptr @nested_receiver(ptr %owner) {
entry:
  %nested = call ptr @malloc(i64 128)
  ret ptr %nested
}

define ptr @receiver_with_nested(ptr %owner) {
entry:
  %direct = call ptr @malloc(i64 64)
  %nested = call ptr @nested_receiver(ptr %owner)
  call void @consume(ptr %nested)
  ret ptr %direct
}

define void @seed_function() {
entry:
  %seed = call ptr @malloc(i64 4096)
  %seed.freeze = freeze ptr %seed
  %field = getelementptr i8, ptr %seed.freeze, i64 8
  %owned = call ptr @malloc(i64 32)
  %owned.freeze = freeze ptr %owned
  store ptr %owned.freeze, ptr %field
  %unrelated = call ptr @malloc(i64 48)
  call void @consume(ptr %unrelated)
  %receiver.arg = select i1 true, ptr %seed.freeze, ptr null
  %first = call ptr @receiver(ptr %receiver.arg)
  %second = call ptr @receiver_with_nested(ptr %receiver.arg)
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

; USE-LABEL: define ptr @receiver
; USE: call ptr @malloc(i64 96)
; USE-LABEL: define ptr @nested_receiver
; USE: call ptr @malloc(i64 128)
; USE-LABEL: define ptr @receiver_with_nested
; USE: call ptr @malloc(i64 64)
; USE-LABEL: define void @seed_function
; USE: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 4, i32 0)
; USE: call ptr @arbiter_alloc_site(i64 32, i64 64, i32 5, i32 0)
; USE: call ptr @malloc(i64 48)
; USE-LABEL: define void @second_seed_function
; USE: call ptr @malloc(i64 4096)

; NONE-LABEL: define ptr @receiver
; NONE: call ptr @malloc(i64 96)
; NONE-LABEL: define void @seed_function
; NONE: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 4, i32 0)
; NONE: call ptr @malloc(i64 32)
; NONE: call ptr @malloc(i64 48)

; MEMBER-CAP-LABEL: define ptr @receiver
; MEMBER-CAP: call ptr @malloc(i64 96)
; MEMBER-CAP-LABEL: define void @seed_function
; MEMBER-CAP: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 4, i32 0)
; MEMBER-CAP: call ptr @arbiter_alloc_site(i64 32, i64 64, i32 5, i32 0)

; MAX-SITES-LABEL: define ptr @receiver
; MAX-SITES: call ptr @malloc(i64 96)
; MAX-SITES-LABEL: define void @seed_function
; MAX-SITES: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 4, i32 0)
; MAX-SITES: call ptr @arbiter_alloc_site(i64 32, i64 64, i32 5, i32 0)

; OVERLAP-LABEL: define ptr @receiver
; OVERLAP: call ptr @malloc(i64 96)
; OVERLAP-LABEL: define void @seed_function
; OVERLAP: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 4, i32 0)
; OVERLAP: call ptr @arbiter_alloc_site(i64 32, i64 64, i32 5, i32 0)
; OVERLAP-LABEL: define void @second_seed_function
; OVERLAP: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 7, i32 0)
