#include "arbiter/LLVM/Passes.h"

#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"

using namespace llvm;

namespace {

bool registerArbiterPipeline(StringRef name, ModulePassManager &manager,
                             ArrayRef<PassBuilder::PipelineElement>) {
  if (name == "arbiter-report-sites") {
    manager.addPass(arbiter::llvm::ReportAllocationSitesPass());
    return true;
  }
  if (name == "arbiter-experiment-all-rewrite") {
    manager.addPass(arbiter::llvm::AllRewriteExperimentPass());
    return true;
  }
  if (name == "arbiter-report-pattern-sites") {
    manager.addPass(arbiter::llvm::PatternReportPass());
    return true;
  }
  if (name == "arbiter-experiment-pattern-rewrite") {
    manager.addPass(arbiter::llvm::PatternRewriteExperimentPass());
    return true;
  }
  return false;
}

} // namespace

extern "C" LLVM_ATTRIBUTE_WEAK PassPluginLibraryInfo llvmGetPassPluginInfo() {
  return {LLVM_PLUGIN_API_VERSION, "ArbiterLLVMPlugin", LLVM_VERSION_STRING,
          [](PassBuilder &builder) {
            builder.registerPipelineParsingCallback(registerArbiterPipeline);
          }};
}
