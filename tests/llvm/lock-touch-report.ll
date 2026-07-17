; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-lock-touch-sites -disable-output %s | FileCheck %s

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

; CHECK: site_id,function,file,line,kind,target
; CHECK-NEXT: 1,patterns,,0,pthread_mutex_lock,%lock
; CHECK-NEXT: 2,patterns,,0,pthread_rwlock_rdlock,%rwlock
; CHECK-NEXT: 3,patterns,,0,atomicrmw,%word
; CHECK-NEXT: 4,patterns,,0,cmpxchg,%word
; CHECK-NEXT: 5,patterns,,0,atomic-store,%word
; CHECK-NEXT: 6,patterns,,0,inline-asm-cmpxchg,%word
