#include "arbiter/LLVM/HotSet/Passes.h"

#include "HotSetOptions.h"
#include "UseBasedHotSet.h"
#include "arbiter/LLVM/AllocationSite.h"
#include "arbiter/LLVM/RewritePlan.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/Twine.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

using namespace llvm;

namespace arbiter::llvm::hotset {
namespace {

constexpr uint32_t kPlacementTargetEnabled = 1u << 0;
constexpr unsigned kPlacementTargetNodeShift = 8;
constexpr uint32_t kPlacementTargetNodeMask =
    0xffu << kPlacementTargetNodeShift;

struct PlacementConfig {
  uint32_t flags = 0;
  int32_t targetNode = -1;
};

[[noreturn]] void failConfig(const Twine &message) {
  report_fatal_error(Twine("arbiter hotset config: ") + message, false);
}

PlacementConfig placementFromOptions() {
  StringRef placement = Placement.getValue();
  if (placement == "local")
    return {};
  if (placement != "target") {
    failConfig(Twine("invalid placement '") + placement +
               "'; expected local or target");
  }
  if (TargetNode > 0xffu)
    failConfig("target node must fit in flags bits 8-15");

  return {kPlacementTargetEnabled |
              ((TargetNode.getValue() << kPlacementTargetNodeShift) &
               kPlacementTargetNodeMask),
          static_cast<int32_t>(TargetNode.getValue())};
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

void emitReport(raw_ostream &stream,
                ArrayRef<HotSetSiteDecision> records,
                const PlacementConfig &placement) {
  stream << "site_id,kind,function,file,line,callee,size_expr,"
            "estimated_bytes,score,role,group_id,selected,flags,target_node,"
            "reasons,member_affinity,member_access_kind,"
            "member_access_depth\n";
  for (const HotSetSiteDecision &record : records) {
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
    writeCsvValue(stream, hotSetRoleName(record.role));
    bool selected = record.role != HotSetRole::Rejected;
    stream << ',' << record.groupId << ','
           << (selected ? "yes" : "no") << ','
           << (selected ? placement.flags : 0) << ','
           << (selected ? placement.targetNode : -1) << ',';
    writeCsvValue(stream, record.reason);
    stream << ',' << record.memberAffinity << ',';
    writeCsvValue(stream, record.memberAccessKind);
    stream << ',' << record.memberAccessDepth << '\n';
  }
}

RewritePlan buildRewritePlan(const HotSetSelection &selection) {
  RewritePlan plan;
  for (const HotSetSiteDecision &record : selection.records) {
    if (record.role == HotSetRole::Rejected)
      continue;

    if (isHeapAllocation(record.site->kind)) {
      plan.selectHeapAllocation(record.site->id, record.reason);
      continue;
    }

    if (isMMapAllocation(record.site->kind))
      plan.selectMMap(record.site->id, record.reason);
  }
  return plan;
}

bool getRuntimeSiteOperands(const CallBase &call, unsigned &siteIdOperand,
                            unsigned &flagsOperand) {
  const auto *callee =
      dyn_cast<Function>(call.getCalledOperand()->stripPointerCasts());
  if (!callee)
    return false;

  StringRef name = callee->getName();
  if (name == "arbiter_alloc_site") {
    siteIdOperand = 2;
    flagsOperand = 3;
  } else if (name == "arbiter_calloc_site" ||
             name == "arbiter_mmap_site") {
    siteIdOperand = 3;
    flagsOperand = 4;
  } else {
    return false;
  }

  return call.arg_size() > flagsOperand;
}

// Generic rewrites emit flags=0; hotset updates only selected site calls.
bool bakePlacementFlags(Module &module, const HotSetSelection &selection,
                        uint32_t placementFlags) {
  std::unordered_map<uint32_t, uint32_t> flagsBySiteId;
  for (const HotSetSiteDecision &record : selection.records) {
    if (record.role != HotSetRole::Rejected)
      flagsBySiteId.emplace(record.site->id, placementFlags);
  }
  if (flagsBySiteId.empty())
    return false;

  bool changed = false;
  for (Function &function : module) {
    for (Instruction &instruction : instructions(function)) {
      auto *call = dyn_cast<CallBase>(&instruction);
      if (!call)
        continue;

      unsigned siteIdOperand = 0;
      unsigned flagsOperand = 0;
      if (!getRuntimeSiteOperands(*call, siteIdOperand, flagsOperand))
        continue;

      const auto *siteId =
          dyn_cast<ConstantInt>(call->getArgOperand(siteIdOperand));
      if (!siteId)
        continue;

      auto flagsIt =
          flagsBySiteId.find(static_cast<uint32_t>(siteId->getZExtValue()));
      if (flagsIt == flagsBySiteId.end())
        continue;

      Value *currentFlags = call->getArgOperand(flagsOperand);
      const auto *constantFlags = dyn_cast<ConstantInt>(currentFlags);
      if (constantFlags && constantFlags->getZExtValue() == flagsIt->second)
        continue;

      call->setArgOperand(
          flagsOperand,
          ConstantInt::get(cast<IntegerType>(currentFlags->getType()),
                           flagsIt->second));
      changed = true;
    }
  }
  return changed;
}

} // namespace

PreservedAnalyses ReportPass::run(Module &module, ModuleAnalysisManager &) {
  PlacementConfig placement = placementFromOptions();
  std::vector<AllocationSite> sites = collectAllocationSites(module);
  HotSetSelection selection = discoverUseBasedHotSet(module, sites);

  std::error_code error;
  std::unique_ptr<raw_fd_ostream> file = openFile(ReportPath, error);
  if (error) {
    failConfig(Twine("failed to open report path '") + ReportPath.getValue() +
               "': " + error.message());
  }

  raw_ostream &stream = file ? *file : outs();
  emitReport(stream, selection.records, placement);
  return PreservedAnalyses::all();
}

PreservedAnalyses RewriteExperimentPass::run(Module &module,
                                             ModuleAnalysisManager &) {
  PlacementConfig placement = placementFromOptions();
  std::vector<AllocationSite> sites = collectAllocationSites(module);
  HotSetSelection selection = discoverUseBasedHotSet(module, sites);
  RewritePlan plan = buildRewritePlan(selection);

  bool changed = false;
  changed |= applyMMapRewrites(module, sites, plan);
  changed |= applyHeapRewrites(module, sites, plan);
  changed |= bakePlacementFlags(module, selection, placement.flags);
  return changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}

} // namespace arbiter::llvm::hotset
