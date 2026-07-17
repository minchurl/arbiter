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
  if (name == "arbiter-report-shared-mutable-sites") {
    manager.addPass(arbiter::llvm::SharedMutableReportPass());
    return true;
  }
  if (name == "arbiter-experiment-shared-mutable-rewrite") {
    manager.addPass(arbiter::llvm::SharedMutableRewriteExperimentPass());
    return true;
  }
  if (name == "arbiter-report-lock-touch-sites") {
    manager.addPass(arbiter::llvm::LockTouchReportPass());
    return true;
  }
  if (name == "arbiter-experiment-lock-touch-instrument") {
    manager.addPass(arbiter::llvm::LockTouchInstrumentPass());
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
