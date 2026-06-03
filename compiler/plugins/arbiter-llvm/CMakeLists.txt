add_llvm_pass_plugin(ArbiterLLVMPlugin
  ArbiterLLVMPlugin.cpp
)

target_link_libraries(ArbiterLLVMPlugin
  PRIVATE
  ArbiterLLVM
)
