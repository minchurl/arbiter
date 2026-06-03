# MLIR Arbiter passes retained for the memref precision/reference path.
# These are not used by the LLVM-only benchmark workflow.
add_mlir_library(ArbiterTransforms
  SelectObjects.cpp
  RewriteAllocations.cpp
  RewriteDeallocations.cpp
  LowerToRuntime.cpp
  Passes.cpp

  LINK_LIBS PUBLIC
  ArbiterDialect
  MLIRArithToLLVM
  MLIRFuncToLLVM
  MLIRIR
  MLIRLLVMCommonConversion
  MLIRLLVMDialect
  MLIRMemRefToLLVM
  MLIRMemRefDialect
  MLIRPass
  MLIRSupport
  MLIRTransformUtils
)
