#include "arbiter/LLVM/HotSet/Passes.h"

#include "HITMRiskScoring.h"
#include "HotSetOptions.h"
#include "arbiter/LLVM/AllocationSite.h"
#include "arbiter/LLVM/RewritePlan.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/Twine.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

#include <memory>
#include <vector>

using namespace llvm;

namespace arbiter::llvm::hotset {
namespace {

HITMSeedPolicy hitmSeedPolicyFromOptions() {
  HITMSeedPolicy policy;
  policy.minScore = HITMMinScore;
  policy.seedLimit = HITMSeedLimit;
  policy.explicitSiteIds = HITMSeedSiteIds;
  policy.requireEscape = HITMRequireEscape;
  policy.requireSync = HITMRequireSync;
  policy.scoring.weightEscapeReturn = HITMWeightEscapeReturn;
  policy.scoring.weightEscapeStore = HITMWeightEscapeStore;
  policy.scoring.weightEscapeCall = HITMWeightEscapeCall;
  policy.scoring.weightSyncAtomic = HITMWeightSyncAtomic;
  policy.scoring.weightSyncStore = HITMWeightSyncStore;
  policy.scoring.weightSyncInlineAsm = HITMWeightSyncInlineAsm;
  policy.scoring.weightSyncFile = HITMWeightSyncFile;
  policy.scoring.weightWorkerEntry = HITMWeightWorkerEntry;
  policy.scoring.weightWorkerReachable = HITMWeightWorkerReachable;
  policy.scoring.weightSize = HITMWeightSize;
  policy.scoring.largeAllocationThreshold = HITMLargeAllocationThreshold;
  policy.scoring.includeDynamicSize = HITMIncludeDynamicSize;
  policy.dynamicSizeEstimate = DynamicSizeEstimate;
  policy.maxEstimatedBytes = MaxEstimatedBytes;
  return policy;
}

[[noreturn]] void failConfig(const Twine &message) {
  report_fatal_error(Twine("arbiter hotset config: ") + message, false);
}

void writeCsvValue(raw_ostream &stream, StringRef value) {
  bool quote = value.contains(',') || value.contains('"') ||
               value.contains('\n') || value.contains('\r') ||
               value.contains(';');
  if (!quote) {
    stream << value;
    return;
  }

  stream << '"';
  for (char character : value) {
    if (character == '"')
      stream << "\"\"";
    else
      stream << character;
  }
  stream << '"';
}

std::unique_ptr<raw_fd_ostream> openFile(StringRef path,
                                         std::error_code &error) {
  if (path.empty() || path == "-")
    return nullptr;
  return std::make_unique<raw_fd_ostream>(path, error, sys::fs::OF_Text);
}

void emitReport(raw_ostream &stream, ArrayRef<HITMSeedDecision> records) {
  stream << "site_id,kind,function,file,line,callee,size_expr,"
            "estimated_bytes,score,role,group_id,selected,reasons\n";
  for (const HITMSeedDecision &record : records) {
    const AllocationSite &site = *record.site;
    stream << site.id << ',';
    writeCsvValue(stream, kindToString(site.kind));
    stream << ',';
    writeCsvValue(stream, site.function);
    stream << ',';
    writeCsvValue(stream, site.file);
    stream << ',' << site.line << ',';
    writeCsvValue(stream, site.callee);
    stream << ',';
    writeCsvValue(stream, site.sizeExpr);
    stream << ',' << record.score.estimatedBytes << ','
           << record.score.value << ',';
    writeCsvValue(stream, record.selected ? "seed" : "rejected");
    stream << ',' << record.groupId << ','
           << (record.selected ? "yes" : "no") << ',';
    writeCsvValue(stream, record.score.reasons);
    stream << '\n';
  }
}

RewritePlan buildRewritePlan(const HITMSeedSelection &selection) {
  RewritePlan plan;
  for (const HITMSeedDecision &record : selection.records) {
    if (!record.selected)
      continue;
    plan.selectHeapAllocation(record.site->id, record.score.reasons);
  }
  return plan;
}

} // namespace

PreservedAnalyses ReportPass::run(Module &module, ModuleAnalysisManager &) {
  std::vector<AllocationSite> sites = collectAllocationSites(module);
  HITMSeedSelection selection =
      selectHITMSeeds(module, sites, hitmSeedPolicyFromOptions());

  std::error_code error;
  std::unique_ptr<raw_fd_ostream> file = openFile(ReportPath, error);
  if (error) {
    failConfig(Twine("failed to open report path '") + ReportPath.getValue() +
               "': " + error.message());
  }

  raw_ostream &stream = file ? *file : outs();
  emitReport(stream, selection.records);
  return PreservedAnalyses::all();
}

PreservedAnalyses RewriteExperimentPass::run(Module &module,
                                             ModuleAnalysisManager &) {
  std::vector<AllocationSite> sites = collectAllocationSites(module);
  HITMSeedSelection selection =
      selectHITMSeeds(module, sites, hitmSeedPolicyFromOptions());
  RewritePlan plan = buildRewritePlan(selection);

  bool changed = applyHeapRewrites(module, sites, plan);
  return changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}

} // namespace arbiter::llvm::hotset
