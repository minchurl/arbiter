add_mlir_dialect_library(ArbiterDialect
  ArbiterDialect.cpp

  DEPENDS
  MLIRArbiterOpsIncGen

  LINK_LIBS PUBLIC
  MLIRIR
  MLIRSideEffectInterfaces
)
