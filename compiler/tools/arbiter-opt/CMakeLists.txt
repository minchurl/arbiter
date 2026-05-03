add_llvm_executable(arbiter-opt arbiter-opt.cpp)
llvm_update_compile_flags(arbiter-opt)

target_link_libraries(arbiter-opt
  PRIVATE
  ArbiterDialect
  ArbiterTransforms
  MLIRArithDialect
  MLIRFuncDialect
  MLIRIR
  MLIRMemRefDialect
  MLIRParser
  MLIRPass
  MLIRSCFDialect
  MLIRSupport
  MLIRTransforms
)

mlir_check_all_link_libraries(arbiter-opt)
