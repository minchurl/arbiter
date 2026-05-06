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
  MLIRSCFDialect
  MLIRSupport
  MLIRTransformUtils
)
