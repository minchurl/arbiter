; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-hitm-seed-sites -arbiter-hitm-weight-published-rmw=3 -disable-output %s | FileCheck %s

target datalayout = "e-p:64:64-i64:64-n8:16:32:64-S128"
%Pair = type { ptr, ptr }
@readonly_sink = global ptr null
@atomic_pointer = global ptr null
@ambiguous = global ptr null

declare ptr @malloc(i64)
declare void @opaque(ptr)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)

define ptr @identity(ptr %p) { ret ptr %p }
define void @touch(ptr %p) {
  %old = atomicrmw add ptr %p, i64 1 monotonic
  ret void
}
define void @member_worker(ptr %owner) {
  %field = getelementptr %Pair, ptr %owner, i64 0, i32 0
  %locks = load ptr, ptr %field
  call void @touch(ptr %locks)
  %other = getelementptr %Pair, ptr %owner, i64 0, i32 1
  %readonly = load ptr, ptr %other
  %v = load i64, ptr %readonly
  ret void
}
define void @member_case() {
  %owner = call ptr @malloc(i64 16)
  %locks = call ptr @malloc(i64 64)
  %readonly = call ptr @malloc(i64 64)
  store ptr %locks, ptr %owner
  %other = getelementptr %Pair, ptr %owner, i64 0, i32 1
  store ptr %readonly, ptr %other
  call void @member_worker(ptr %owner)
  ret void
}
; CHECK: 1,malloc,member_case,{{.*}}"{{[^"\n]*}}no-sync-mutable"
; CHECK: 2,malloc,member_case,{{.*}}object-pointee-atomic-rmw
; CHECK: 3,malloc,member_case,{{.*}}"{{[^"\n]*}}no-sync-mutable"

define void @return_case() {
  %yes = call ptr @malloc(i64 64)
  %no = call ptr @malloc(i64 64)
  %a = call ptr @identity(ptr %yes)
  %b = call ptr @identity(ptr %no)
  store ptr %b, ptr @readonly_sink
  call void @touch(ptr %a)
  ret void
}
; CHECK: 4,malloc,return_case,{{.*}}object-pointee-atomic-rmw
; CHECK: 5,malloc,return_case,{{.*}}"{{[^"\n]*}}no-sync-mutable"

define void @copy_case() {
  %source = alloca ptr
  %destination = alloca ptr
  %object = call ptr @malloc(i64 64)
  store ptr %object, ptr %source
  call void @llvm.memcpy.p0.p0.i64(ptr %destination, ptr %source, i64 8, i1 false)
  %p = load ptr, ptr %destination
  call void @touch(ptr %p)
  ret void
}
; CHECK: 6,malloc,copy_case,{{.*}}object-pointee-atomic-rmw

define void @value_not_address() {
  %datum = call ptr @malloc(i64 64)
  %old = atomicrmw xchg ptr @atomic_pointer, ptr %datum seq_cst
  ret void
}
; CHECK-NOT: 7,malloc,value_not_address,{{.*}}object-pointee-atomic-rmw
; CHECK: 7,malloc,value_not_address,

define void @unknown_external() {
  %object = call ptr @malloc(i64 64)
  call void @opaque(ptr %object)
  ret void
}
; CHECK: 8,malloc,unknown_external,{{.*}}"{{[^"\n]*}}no-sync-mutable"

define void @ambiguous_case(i1 %which) {
  %a = call ptr @malloc(i64 64)
  %b = call ptr @malloc(i64 64)
  %p = select i1 %which, ptr %a, ptr %b
  call void @touch(ptr %p)
  ret void
}
; CHECK: 9,malloc,ambiguous_case,{{.*}}"{{[^"\n]*}}no-sync-mutable"
; CHECK: 10,malloc,ambiguous_case,{{.*}}"{{[^"\n]*}}no-sync-mutable"

; Two distinct fields joined by select must not pull in the middle field.
define void @field_alternatives(i1 %which) {
  %slots = alloca [3 x ptr]
  %data = call ptr @malloc(i64 64)
  %middle = getelementptr [3 x ptr], ptr %slots, i64 0, i64 1
  store ptr %data, ptr %middle
  %last = getelementptr [3 x ptr], ptr %slots, i64 0, i64 2
  %p = select i1 %which, ptr %slots, ptr %last
  %q = load ptr, ptr %p
  call void @touch(ptr %q)
  ret void
}
; CHECK: 11,malloc,field_alternatives,{{.*}}"{{[^"\n]*}}no-sync-mutable"

; An opaque function's result must not vanish from an alias union.
declare ptr @opaque_factory()
define void @unknown_result(i1 %choose) {
  %known = call ptr @malloc(i64 64)
  %unknown = call ptr @opaque_factory()
  %address = select i1 %choose, ptr %known, ptr %unknown
  call void @touch(ptr %address)
  ret void
}
; CHECK: 12,malloc,unknown_result,{{.*}}"{{[^"\n]*}}no-sync-mutable"
