#ifndef ARBITER_LLVM_HITM_SEED_PASSES_H
#define ARBITER_LLVM_HITM_SEED_PASSES_H

#include "llvm/IR/PassManager.h"

namespace arbiter::llvm::hitm_seed {

struct ReportPass : public ::llvm::PassInfoMixin<ReportPass> {
  ::llvm::PreservedAnalyses run(::llvm::Module &module,
                                ::llvm::ModuleAnalysisManager &manager);
};

struct RewriteExperimentPass
    : public ::llvm::PassInfoMixin<RewriteExperimentPass> {
  ::llvm::PreservedAnalyses run(::llvm::Module &module,
                                ::llvm::ModuleAnalysisManager &manager);
};

} // namespace arbiter::llvm::hitm_seed

#endif // ARBITER_LLVM_HITM_SEED_PASSES_H
