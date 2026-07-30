#ifndef ARBITER_LLVM_HOTSET_PASSES_H
#define ARBITER_LLVM_HOTSET_PASSES_H

#include "llvm/IR/PassManager.h"

namespace arbiter::llvm::hotset {

struct ReportPass : public ::llvm::PassInfoMixin<ReportPass> {
  ::llvm::PreservedAnalyses run(::llvm::Module &module,
                                ::llvm::ModuleAnalysisManager &manager);
};

struct RewriteExperimentPass
    : public ::llvm::PassInfoMixin<RewriteExperimentPass> {
  ::llvm::PreservedAnalyses run(::llvm::Module &module,
                                ::llvm::ModuleAnalysisManager &manager);
};

} // namespace arbiter::llvm::hotset

#endif // ARBITER_LLVM_HOTSET_PASSES_H
