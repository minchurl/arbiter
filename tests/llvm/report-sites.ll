; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-report-sites -disable-output %s | FileCheck %s

declare ptr @malloc(i64)
declare void @free(ptr)

define void @main() {
entry:
  %p = call ptr @malloc(i64 16)
  call void @free(ptr %p)
  ret void
}

; CHECK: site_id,kind,function,file,line,callee,size_expr
; CHECK: 1,malloc,main
; CHECK: malloc
; CHECK: 2,free,main
; CHECK: free
