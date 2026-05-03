add_mlir_library(ArbiterTransforms
  MarkCandidates.cpp
  RewriteAllocations.cpp
  RewriteDeallocations.cpp
  Passes.cpp

  LINK_LIBS PUBLIC
  ArbiterDialect
  MLIRIR
  MLIRMemRefDialect
  MLIRPass
  MLIRSupport
  MLIRTransformUtils
)
