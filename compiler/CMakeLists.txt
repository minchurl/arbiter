add_subdirectory(llvm)

if(ARBITER_ENABLE_MLIR_LEGACY)
  add_subdirectory(mlir-legacy)
endif()
