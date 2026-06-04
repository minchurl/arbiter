; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-pattern-rewrite -S %s | FileCheck %s
; RUN: opt -load-pass-plugin %shlibdir/ArbiterLLVMPlugin%shlibext -passes=arbiter-experiment-pattern-rewrite -arbiter-pattern-min-score=9 -S %s | FileCheck %s --check-prefix=THRESHOLD

declare ptr @malloc(i64)
declare void @free(ptr)
declare ptr @_Znam(i64)
declare ptr @_Znwm(i64)

define void @allocate_new_block() !dbg !10 {
entry:
  %p = call ptr @malloc(i64 64), !dbg !20
  call void @free(ptr %p), !dbg !21
  ret void, !dbg !22
}

define void @group_init() !dbg !30 {
entry:
  %a = call ptr @_Znam(i64 128), !dbg !40
  ret void, !dbg !41
}

define void @load_ycsb_transaction() !dbg !50 {
entry:
  %q = call ptr @_Znwm(i64 32), !dbg !60
  ret void, !dbg !61
}

; CHECK-LABEL: define void @allocate_new_block
; CHECK: call ptr @arbiter_alloc_site(i64 64, i64 64, i32 1, i32 0)
; CHECK: call void @arbiter_free_maybe(ptr %p)
; CHECK-LABEL: define void @group_init
; CHECK: call ptr @arbiter_alloc_site(i64 128, i64 64, i32 3, i32 0)
; CHECK-LABEL: define void @load_ycsb_transaction
; CHECK: call ptr @_Znwm(i64 32)
; CHECK-NOT: call ptr @arbiter_alloc_site(i64 32
; CHECK-DAG: declare ptr @arbiter_alloc_site(i64, i64, i32, i32)
; CHECK-DAG: declare void @arbiter_free_maybe(ptr)

; THRESHOLD-LABEL: define void @allocate_new_block
; THRESHOLD: call ptr @arbiter_alloc_site(i64 64, i64 64, i32 1, i32 0)
; THRESHOLD-LABEL: define void @group_init
; THRESHOLD: call ptr @_Znam(i64 128)
; THRESHOLD-NOT: call ptr @arbiter_alloc_site(i64 128

!llvm.dbg.cu = !{!0}
!llvm.module.flags = !{!3, !4}

!0 = distinct !DICompileUnit(language: DW_LANG_C_plus_plus_14, file: !1, producer: "arbiter-test", isOptimized: false, runtimeVersion: 0, emissionKind: LineTablesOnly)
!1 = !DIFile(filename: "pattern-rewrite.cpp", directory: "/tmp")
!2 = !DISubroutineType(types: !5)
!3 = !{i32 2, !"Debug Info Version", i32 3}
!4 = !{i32 2, !"Dwarf Version", i32 4}
!5 = !{null}
!6 = !DIFile(filename: "xindex_buffer_impl.h", directory: "/tmp")
!7 = !DIFile(filename: "xindex_group_impl.h", directory: "/tmp")
!8 = !DIFile(filename: "ycsb_bench.cpp", directory: "/tmp")
!10 = distinct !DISubprogram(name: "allocate_new_block", scope: !6, file: !6, line: 831, type: !2, scopeLine: 831, spFlags: DISPFlagDefinition, unit: !0)
!20 = !DILocation(line: 832, column: 25, scope: !10)
!21 = !DILocation(line: 833, column: 3, scope: !10)
!22 = !DILocation(line: 834, column: 1, scope: !10)
!30 = distinct !DISubprogram(name: "init", scope: !7, file: !7, line: 35, type: !2, scopeLine: 35, spFlags: DISPFlagDefinition, unit: !0)
!40 = !DILocation(line: 41, column: 16, scope: !30)
!41 = !DILocation(line: 42, column: 1, scope: !30)
!50 = distinct !DISubprogram(name: "load_ycsb_transaction", scope: !8, file: !8, line: 208, type: !2, scopeLine: 208, spFlags: DISPFlagDefinition, unit: !0)
!60 = !DILocation(line: 235, column: 3, scope: !50)
!61 = !DILocation(line: 236, column: 1, scope: !50)
