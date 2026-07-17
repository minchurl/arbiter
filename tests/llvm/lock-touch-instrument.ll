; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-lock-touch-instrument -S %s | FileCheck %s

declare i32 @pthread_mutex_lock(ptr)
declare i32 @pthread_mutex_unlock(ptr)
declare i32 @pthread_rwlock_rdlock(ptr)

define void @patterns(ptr %lock, ptr %rwlock, ptr %word, i32 %value) {
entry:
  %r0 = call i32 @pthread_mutex_lock(ptr %lock)
  %r1 = call i32 @pthread_mutex_unlock(ptr %lock)
  %r2 = call i32 @pthread_rwlock_rdlock(ptr %rwlock)
  %old = atomicrmw add ptr %word, i32 1 seq_cst, align 4
  %pair = cmpxchg ptr %word, i32 0, i32 1 acquire monotonic, align 4
  store atomic i32 %value, ptr %word seq_cst, align 4
  store volatile i32 %value, ptr %word, align 4
  store i32 %value, ptr %word, align 4
  %asm = call i32 asm sideeffect "lock; cmpxchgl $2,$1", "={ax},=*m,r,0,*m,~{cc},~{dirflag},~{fpsr},~{flags}"(ptr elementtype(i32) %word, i32 1, i32 0, ptr elementtype(i32) %word)
  call void asm sideeffect "mfence", "~{memory},~{dirflag},~{fpsr},~{flags}"()
  ret void
}

; CHECK-LABEL: define void @patterns
; CHECK: call void @arbiter_lock_touch(ptr %lock, i32 1)
; CHECK-NEXT: %r0 = call i32 @pthread_mutex_lock(ptr %lock)
; CHECK-NEXT: %r1 = call i32 @pthread_mutex_unlock(ptr %lock)
; CHECK-NEXT: call void @arbiter_lock_touch(ptr %rwlock, i32 2)
; CHECK-NEXT: %r2 = call i32 @pthread_rwlock_rdlock(ptr %rwlock)
; CHECK-NEXT: call void @arbiter_lock_touch(ptr %word, i32 3)
; CHECK-NEXT: %old = atomicrmw add ptr %word, i32 1 seq_cst, align 4
; CHECK-NEXT: call void @arbiter_lock_touch(ptr %word, i32 4)
; CHECK-NEXT: %pair = cmpxchg ptr %word, i32 0, i32 1 acquire monotonic, align 4
; CHECK-NEXT: call void @arbiter_lock_touch(ptr %word, i32 5)
; CHECK-NEXT: store atomic i32 %value, ptr %word seq_cst, align 4
; CHECK-NEXT: store volatile i32 %value, ptr %word, align 4
; CHECK-NEXT: store i32 %value, ptr %word, align 4
; CHECK-NEXT: call void @arbiter_lock_touch(ptr %word, i32 6)
; CHECK-NEXT: %asm = call i32 asm sideeffect
; CHECK-NEXT: call void asm sideeffect "mfence"
; CHECK-DAG: declare void @arbiter_lock_touch(ptr, i32)
