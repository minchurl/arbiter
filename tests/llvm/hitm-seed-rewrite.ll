; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hitm-seed-rewrite -arbiter-hitm-seed-site-ids=4 -S %s | FileCheck %s --check-prefix=SINGLE
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hitm-seed-rewrite -arbiter-hitm-seed-site-ids=4,7 -S %s | FileCheck %s --check-prefix=MULTI
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-hitm-seed-rewrite -arbiter-hitm-min-score=9 -arbiter-hitm-seed-limit=1 -S %s | FileCheck %s --check-prefix=AUTO

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

; SINGLE-LABEL: define ptr @receiver
; SINGLE: call ptr @malloc(i64 96)
; SINGLE-LABEL: define void @seed_function
; SINGLE: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 4, i32 0)
; SINGLE: call ptr @malloc(i64 32)
; SINGLE: call ptr @malloc(i64 48)
; SINGLE-LABEL: define void @second_seed_function
; SINGLE: call ptr @malloc(i64 4096)

; MULTI-LABEL: define void @seed_function
; MULTI: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 4, i32 0)
; MULTI: call ptr @malloc(i64 32)
; MULTI-LABEL: define void @second_seed_function
; MULTI: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 7, i32 0)

; AUTO-LABEL: define void @seed_function
; AUTO: call ptr @arbiter_alloc_site(i64 4096, i64 64, i32 4, i32 0)
; AUTO-LABEL: define void @second_seed_function
; AUTO: call ptr @malloc(i64 4096)
