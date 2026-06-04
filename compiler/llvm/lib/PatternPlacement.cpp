#include "arbiter/LLVM/Passes.h"

#include "arbiter/LLVM/AllocationSite.h"
#include "arbiter/LLVM/RewritePlan.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

using namespace llvm;

namespace arbiter::llvm {
namespace {

struct PatternDecision {
  uint32_t score = 0;
  std::vector<std::string> reasons;
};

bool contains(StringRef value, StringRef needle) {
  return value.find(needle) != StringRef::npos;
}

bool isXIndexBufferImpl(const AllocationSite &site) {
  return contains(site.file, "xindex_buffer_impl.h");
}

bool isXIndexGroupImpl(const AllocationSite &site) {
  return contains(site.file, "xindex_group_impl.h");
}

bool isXIndexModelImpl(const AllocationSite &site) {
  return contains(site.file, "xindex_model_impl.h");
}

bool isXIndexRootOrIndexMetadata(const AllocationSite &site) {
  return contains(site.file, "xindex_root_impl.h") ||
         contains(site.file, "xindex_impl.h") ||
         contains(site.file, "xindex_root.h") ||
         contains(site.file, "xindex.h");
}

bool isYCSBDriver(const AllocationSite &site) {
  return contains(site.file, "ycsb_bench");
}

bool isRCUStatusAllocation(const AllocationSite &site) {
  return contains(site.file, "xindex_util.h") ||
         contains(site.function, "rcu_init");
}

bool isBufferNodeBlock(const AllocationSite &site) {
  bool matchesAllocator = contains(site.function, "allocate_new_block") ||
                          (site.line >= 830 && site.line <= 834);
  return isXIndexBufferImpl(site) && matchesAllocator &&
         site.kind == AllocationKind::Malloc;
}

bool isGroupDataArray(const AllocationSite &site) {
  return isXIndexGroupImpl(site) && site.kind == AllocationKind::CxxNewArray &&
         site.line >= 35 && site.line <= 60;
}

bool isGroupBufferObject(const AllocationSite &site) {
  return isXIndexGroupImpl(site) && site.kind == AllocationKind::CxxNew &&
         site.line >= 75 && site.line <= 155;
}

std::string joinReasons(ArrayRef<std::string> reasons) {
  std::string result;
  raw_string_ostream os(result);
  for (size_t i = 0; i < reasons.size(); ++i) {
    if (i != 0)
      os << ';';
    os << reasons[i];
  }
  return os.str();
}

void csvValue(raw_ostream &os, StringRef value) {
  bool quote = value.contains(',') || value.contains('"') ||
               value.contains('\n') || value.contains('\r') ||
               value.contains(';');
  if (!quote) {
    os << value;
    return;
  }

  os << '"';
  for (char ch : value) {
    if (ch == '"')
      os << "\"\"";
    else
      os << ch;
  }
  os << '"';
}

std::unique_ptr<raw_fd_ostream> openFile(StringRef path,
                                         std::error_code &error) {
  if (path.empty() || path == "-")
    return nullptr;
  return std::make_unique<raw_fd_ostream>(path, error, sys::fs::OF_Text);
}

PatternDecision scoreXIndexYCSBPattern(const AllocationSite &site) {
  PatternDecision decision;

  if (!isHeapAllocation(site.kind)) {
    decision.reasons.push_back("not-heap-allocation");
    return decision;
  }

  if (isBufferNodeBlock(site)) {
    decision.score = 9;
    decision.reasons = {"xindex-buffer-node-block", "worker-reachable",
                        "lock-version", "mutable-vals"};
    return decision;
  }

  if (isGroupDataArray(site)) {
    decision.score = 8;
    decision.reasons = {"xindex-group-data-array", "worker-reachable",
                        "atomic-val", "update-path"};
    return decision;
  }

  if (isGroupBufferObject(site)) {
    decision.score = 6;
    decision.reasons = {"xindex-buffer-object", "conflict-chain",
                        "node-block-selected-separately"};
    return decision;
  }

  if (isYCSBDriver(site)) {
    decision.score = 1;
    decision.reasons = {"ycsb-driver-or-trace", "read-mostly-input"};
    return decision;
  }

  if (isXIndexModelImpl(site)) {
    decision.score = 1;
    decision.reasons = {"model-training-temp", "not-foreground-hot-path"};
    return decision;
  }

  if (isRCUStatusAllocation(site)) {
    decision.score = 1;
    decision.reasons = {"rcu-status", "per-worker-slot"};
    return decision;
  }

  if (isXIndexRootOrIndexMetadata(site)) {
    decision.score = 2;
    decision.reasons = {"xindex-root-or-metadata", "read-mostly"};
    return decision;
  }

  decision.reasons.push_back("no-xindex-ycsb-pattern");
  return decision;
}

PatternDecision scorePattern(const AllocationSite &site) {
  if (ArbiterPatternFocus == "xindex-ycsb")
    return scoreXIndexYCSBPattern(site);

  PatternDecision decision;
  decision.reasons.push_back("unsupported-focus");
  return decision;
}

bool isSelected(const AllocationSite &site, const PatternDecision &decision) {
  return isHeapAllocation(site.kind) && decision.score >= ArbiterPatternMinScore;
}

void emitPatternReport(raw_ostream &os, ArrayRef<AllocationSite> sites) {
  os << "site_id,kind,function,file,line,callee,size_expr,score,selected,"
        "reasons\n";
  for (const AllocationSite &site : sites) {
    PatternDecision decision = scorePattern(site);
    os << site.id << ',';
    csvValue(os, kindToString(site.kind));
    os << ',';
    csvValue(os, site.function);
    os << ',';
    csvValue(os, site.file);
    os << ',' << site.line << ',';
    csvValue(os, site.callee);
    os << ',';
    csvValue(os, site.sizeExpr);
    os << ',' << decision.score << ','
       << (isSelected(site, decision) ? "yes" : "no") << ',';
    csvValue(os, joinReasons(decision.reasons));
    os << '\n';
  }
}

RewritePlan buildPatternRewritePlan(ArrayRef<AllocationSite> sites) {
  RewritePlan plan;
  for (const AllocationSite &site : sites) {
    PatternDecision decision = scorePattern(site);
    if (isSelected(site, decision))
      plan.selectHeapAllocation(site.id, joinReasons(decision.reasons));
  }
  return plan;
}

} // namespace

PreservedAnalyses PatternReportPass::run(Module &module,
                                         ModuleAnalysisManager &) {
  std::vector<AllocationSite> sites = collectAllocationSites(module);

  std::error_code ec;
  std::unique_ptr<raw_fd_ostream> file =
      openFile(ArbiterPatternReportPath, ec);
  if (ec) {
    errs() << "arbiter: failed to open pattern report path "
           << ArbiterPatternReportPath << ": " << ec.message() << "\n";
    return PreservedAnalyses::all();
  }

  raw_ostream &os = file ? *file : outs();
  emitPatternReport(os, sites);
  return PreservedAnalyses::all();
}

PreservedAnalyses PatternRewriteExperimentPass::run(
    Module &module, ModuleAnalysisManager &manager) {
  (void)manager;

  std::vector<AllocationSite> sites = collectAllocationSites(module);
  RewritePlan plan = buildPatternRewritePlan(sites);

  bool changed = false;
  changed |= applyHeapRewrites(module, sites, plan);
  return changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}

} // namespace arbiter::llvm
