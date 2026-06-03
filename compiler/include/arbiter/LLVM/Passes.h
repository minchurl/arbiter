#ifndef ARBITER_LLVM_PASSES_H
#define ARBITER_LLVM_PASSES_H

#include "llvm/IR/PassManager.h"
#include "llvm/Support/CommandLine.h"

#include <string>

namespace arbiter::llvm {

extern ::llvm::cl::opt<std::string> ArbiterReportPath;
extern ::llvm::cl::opt<unsigned> ArbiterDefaultAlignment;

struct ReportAllocationSitesPass
    : public ::llvm::PassInfoMixin<ReportAllocationSitesPass> {
  ::llvm::PreservedAnalyses run(::llvm::Module &module,
                                ::llvm::ModuleAnalysisManager &manager);
};

struct AllRewriteExperimentPass
    : public ::llvm::PassInfoMixin<AllRewriteExperimentPass> {
  ::llvm::PreservedAnalyses run(::llvm::Module &module,
                                ::llvm::ModuleAnalysisManager &manager);
};

} // namespace arbiter::llvm

#endif // ARBITER_LLVM_PASSES_H
