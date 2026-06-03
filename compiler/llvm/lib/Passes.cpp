#include "arbiter/LLVM/Passes.h"

#include "arbiter/LLVM/AllocationSite.h"
#include "arbiter/LLVM/RewritePlan.h"

using namespace llvm;

namespace arbiter::llvm {

cl::opt<std::string> ArbiterReportPath(
    "arbiter-report-path",
    cl::desc("Path for Arbiter LLVM site reports; '-' means stdout"),
    cl::init("-"));

cl::opt<unsigned> ArbiterDefaultAlignment(
    "arbiter-default-alignment",
    cl::desc("Default alignment passed to Arbiter heap allocation calls"),
    cl::init(64));

PreservedAnalyses AllRewriteExperimentPass::run(
    Module &module, ModuleAnalysisManager &manager) {
  (void)manager;

  std::vector<AllocationSite> sites = collectAllocationSites(module);
  RewritePlan plan = buildAllRewritePlan(sites);

  bool changed = false;
  changed |= applyMMapRewrites(module, sites, plan);
  changed |= applyHeapRewrites(module, sites, plan);
  return changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}

} // namespace arbiter::llvm
