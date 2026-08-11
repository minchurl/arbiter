#include "HITMRiskScoring.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/Twine.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <limits>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

using namespace llvm;

namespace arbiter::llvm::hotset {
namespace {

struct FunctionSyncInfo {
  bool atomicRmwOrCmpXchg = false;
  bool atomicOrVolatileStore = false;
  bool lockInlineAsm = false;
};

struct EscapeSignals {
  bool returns = false;
  bool stores = false;
  bool calls = false;
};

struct ScoreDecision {
  uint64_t value = 0;
  bool hasEscape = false;
  bool hasSyncOrMutable = false;
  std::vector<std::string> reasons;
};

struct SizeInfo {
  bool dynamic = false;
  uint64_t estimatedBytes = 0;
};

struct ScoringContext {
  DenseMap<const Function *, FunctionSyncInfo> functionSync;
  std::unordered_set<std::string> filesWithSyncMutation;
  std::vector<const Function *> workerEntries;
  std::unordered_set<const Function *> allWorkerReachable;
};

bool contains(StringRef value, StringRef needle) {
  return value.find(needle) != StringRef::npos;
}

StringRef calledName(const CallBase &call) {
  const Value *called = call.getCalledOperand()->stripPointerCasts();
  if (const auto *function = dyn_cast<Function>(called))
    return function->getName();
  return StringRef();
}

const Function *siteFunction(const AllocationSite &site) {
  return site.call ? site.call->getFunction() : nullptr;
}

std::string getDebugFile(const DILocation *location) {
  if (!location)
    return "";

  StringRef filename = location->getFilename();
  StringRef directory = location->getDirectory();
  if (filename.empty())
    return "";
  if (sys::path::is_absolute(filename) || directory.empty())
    return filename.str();

  SmallString<256> path(directory);
  sys::path::append(path, filename);
  return path.str().str();
}

std::string getInstructionFile(const Instruction &instruction) {
  DebugLoc debugLocation = instruction.getDebugLoc();
  const DILocation *location =
      debugLocation ? debugLocation.get() : nullptr;
  return getDebugFile(location);
}

bool isLockOrCmpXchgInlineAsm(const CallBase &call) {
  const auto *assembly =
      dyn_cast<InlineAsm>(call.getCalledOperand()->stripPointerCasts());
  if (!assembly)
    return false;

  StringRef text = assembly->getAsmString();
  return contains(text, "lock") || contains(text, "cmpxchg");
}

bool isSyncMutation(const Instruction &instruction) {
  if (isa<AtomicRMWInst>(instruction) ||
      isa<AtomicCmpXchgInst>(instruction))
    return true;

  if (const auto *store = dyn_cast<StoreInst>(&instruction))
    return store->isAtomic() || store->isVolatile();

  if (const auto *call = dyn_cast<CallBase>(&instruction))
    return isLockOrCmpXchgInlineAsm(*call);

  return false;
}

bool isTransparentPointerTransform(const User *user) {
  if (isa<PHINode>(user) || isa<SelectInst>(user) ||
      isa<FreezeInst>(user))
    return true;

  const auto *operation = dyn_cast<Operator>(user);
  if (!operation)
    return false;

  switch (operation->getOpcode()) {
  case Instruction::AddrSpaceCast:
  case Instruction::BitCast:
  case Instruction::GetElementPtr:
    return true;
  default:
    return false;
  }
}

bool isIgnoredEscapeCall(const CallBase &call) {
  AllocationKind kind = classifyCall(call);
  if (isHeapDeallocation(kind) || isMMapDeallocation(kind))
    return true;

  if (const Function *callee = call.getCalledFunction())
    return callee->isIntrinsic();

  return false;
}

bool callUsesValueAsArgument(const CallBase &call, const Value *value) {
  for (const Use &argument : call.args()) {
    if (argument.get() == value)
      return true;
  }
  return false;
}

EscapeSignals analyzeEscapes(const AllocationSite &site) {
  EscapeSignals signals;
  if (!site.call)
    return signals;

  SmallVector<std::pair<const Value *, unsigned>, 16> worklist;
  SmallPtrSet<const Value *, 32> visited;
  worklist.push_back({site.call, 0});
  visited.insert(site.call);

  while (!worklist.empty()) {
    auto [value, depth] = worklist.pop_back_val();
    for (const User *user : value->users()) {
      if (isa<ReturnInst>(user)) {
        signals.returns = true;
        continue;
      }

      if (const auto *store = dyn_cast<StoreInst>(user)) {
        if (store->getValueOperand() == value)
          signals.stores = true;
        continue;
      }

      if (const auto *call = dyn_cast<CallBase>(user)) {
        if (callUsesValueAsArgument(*call, value) &&
            !isIgnoredEscapeCall(*call))
          signals.calls = true;
        continue;
      }

      if (depth >= 6 || !isTransparentPointerTransform(user))
        continue;

      if (visited.insert(user).second)
        worklist.push_back({user, depth + 1});
    }
  }

  return signals;
}

const Function *getPThreadStartRoutine(const CallBase &call) {
  if (calledName(call) != "pthread_create" || call.arg_size() < 3)
    return nullptr;

  const Value *startRoutine = call.getArgOperand(2)->stripPointerCasts();
  return dyn_cast<Function>(startRoutine);
}

DenseMap<const Function *, SmallVector<const Function *, 8>>
buildDirectCallGraph(Module &module) {
  DenseMap<const Function *, SmallVector<const Function *, 8>> graph;

  for (Function &function : module) {
    if (function.isDeclaration())
      continue;

    for (Instruction &instruction : instructions(function)) {
      const auto *call = dyn_cast<CallBase>(&instruction);
      if (!call)
        continue;

      const auto *callee =
          dyn_cast<Function>(call->getCalledOperand()->stripPointerCasts());
      if (!callee || callee->isDeclaration())
        continue;

      graph[&function].push_back(callee);
    }
  }

  return graph;
}

void collectWorkerReachability(
    const DenseMap<const Function *, SmallVector<const Function *, 8>> &graph,
    ScoringContext &context) {
  for (const Function *entry : context.workerEntries) {
    std::unordered_set<const Function *> reachable;
    SmallVector<const Function *, 16> worklist;
    reachable.insert(entry);
    worklist.push_back(entry);

    while (!worklist.empty()) {
      const Function *function = worklist.pop_back_val();
      auto graphIt = graph.find(function);
      if (graphIt == graph.end())
        continue;

      for (const Function *callee : graphIt->second) {
        if (reachable.insert(callee).second)
          worklist.push_back(callee);
      }
    }

    context.allWorkerReachable.insert(reachable.begin(), reachable.end());
  }
}

ScoringContext buildContext(Module &module) {
  ScoringContext context;
  std::unordered_set<const Function *> knownWorkerEntries;

  for (Function &function : module) {
    if (function.isDeclaration())
      continue;

    FunctionSyncInfo syncInfo;
    for (Instruction &instruction : instructions(function)) {
      if (isa<AtomicRMWInst>(instruction) ||
          isa<AtomicCmpXchgInst>(instruction)) {
        syncInfo.atomicRmwOrCmpXchg = true;
      } else if (const auto *store = dyn_cast<StoreInst>(&instruction)) {
        syncInfo.atomicOrVolatileStore |=
            store->isAtomic() || store->isVolatile();
      } else if (const auto *call = dyn_cast<CallBase>(&instruction)) {
        syncInfo.lockInlineAsm |= isLockOrCmpXchgInlineAsm(*call);
        if (const Function *entry = getPThreadStartRoutine(*call)) {
          if (knownWorkerEntries.insert(entry).second)
            context.workerEntries.push_back(entry);
        }
      }

      if (isSyncMutation(instruction)) {
        std::string file = getInstructionFile(instruction);
        if (!file.empty())
          context.filesWithSyncMutation.insert(std::move(file));
      }
    }

    if (syncInfo.atomicRmwOrCmpXchg || syncInfo.atomicOrVolatileStore ||
        syncInfo.lockInlineAsm)
      context.functionSync[&function] = syncInfo;
  }

  DenseMap<const Function *, SmallVector<const Function *, 8>> graph =
      buildDirectCallGraph(module);
  collectWorkerReachability(graph, context);
  return context;
}

bool getConstantInt(Value *value, uint64_t &result) {
  auto *constant = dyn_cast_or_null<ConstantInt>(value);
  if (!constant)
    return false;
  result = constant->getZExtValue();
  return true;
}

SizeInfo estimateAllocationSize(const AllocationSite &site,
                                uint64_t dynamicEstimate) {
  CallBase *call = site.call;
  if (!call ||
      (!isHeapAllocation(site.kind) && !isMMapAllocation(site.kind)))
    return {};

  if (site.kind == AllocationKind::Calloc) {
    if (call->arg_size() < 2)
      return {true, dynamicEstimate};

    uint64_t count = 0;
    uint64_t elementSize = 0;
    if (!getConstantInt(call->getArgOperand(0), count) ||
        !getConstantInt(call->getArgOperand(1), elementSize))
      return {true, dynamicEstimate};

    if (elementSize != 0 &&
        count > std::numeric_limits<uint64_t>::max() / elementSize)
      return {true, dynamicEstimate};
    return {false, count * elementSize};
  }

  unsigned sizeOperand = isMMapAllocation(site.kind) ? 1 : 0;
  if (call->arg_size() <= sizeOperand)
    return {true, dynamicEstimate};

  uint64_t size = 0;
  if (!getConstantInt(call->getArgOperand(sizeOperand), size))
    return {true, dynamicEstimate};
  return {false, size};
}

std::string joinReasons(ArrayRef<std::string> reasons) {
  std::string result;
  raw_string_ostream stream(result);
  for (size_t index = 0; index < reasons.size(); ++index) {
    if (index != 0)
      stream << ';';
    stream << reasons[index];
  }
  return stream.str();
}

void addEscapeScore(const EscapeSignals &escapes, const HITMRiskPolicy &policy,
                    ScoreDecision &decision) {
  if (escapes.returns) {
    decision.value += policy.weightEscapeReturn;
    decision.hasEscape = true;
    decision.reasons.push_back("escapes-return");
  }

  if (escapes.stores) {
    decision.value += policy.weightEscapeStore;
    decision.hasEscape = true;
    decision.reasons.push_back("escapes-store");
  }

  if (escapes.calls) {
    decision.value += policy.weightEscapeCall;
    decision.hasEscape = true;
    decision.reasons.push_back("escapes-call");
  }
}

void addSyncScore(const AllocationSite &site, const ScoringContext &context,
                  const HITMRiskPolicy &policy, ScoreDecision &decision) {
  const Function *function = siteFunction(site);
  bool hasFunctionSync = false;

  if (function) {
    auto syncIt = context.functionSync.find(function);
    if (syncIt != context.functionSync.end()) {
      const FunctionSyncInfo &syncInfo = syncIt->second;
      if (syncInfo.atomicRmwOrCmpXchg) {
        decision.value += policy.weightSyncAtomic;
        decision.reasons.push_back(
            "sync-atomic-rmw-or-cmpxchg-same-function");
        hasFunctionSync = true;
      }
      if (syncInfo.atomicOrVolatileStore) {
        decision.value += policy.weightSyncStore;
        decision.reasons.push_back(
            "sync-atomic-or-volatile-store-same-function");
        hasFunctionSync = true;
      }
      if (syncInfo.lockInlineAsm) {
        decision.value += policy.weightSyncInlineAsm;
        decision.reasons.push_back("sync-inline-asm-same-function");
        hasFunctionSync = true;
      }
    }
  }

  if (hasFunctionSync) {
    decision.hasSyncOrMutable = true;
    return;
  }

  if (!site.file.empty() &&
      context.filesWithSyncMutation.count(site.file) != 0) {
    decision.value += policy.weightSyncFile;
    decision.hasSyncOrMutable = true;
    decision.reasons.push_back("sync-mutation-same-file");
  }
}

void addThreadScore(const AllocationSite &site, const ScoringContext &context,
                    const HITMRiskPolicy &policy, ScoreDecision &decision) {
  const Function *function = siteFunction(site);
  if (!function)
    return;

  for (const Function *entry : context.workerEntries) {
    if (function == entry) {
      decision.value += policy.weightWorkerEntry;
      decision.reasons.push_back("pthread-worker-entry");
      return;
    }
  }

  if (context.allWorkerReachable.count(function) != 0) {
    decision.value += policy.weightWorkerReachable;
    decision.reasons.push_back("pthread-worker-reachable");
  }
}

void addSizeScore(const SizeInfo &size, const HITMRiskPolicy &policy,
                  ScoreDecision &decision) {
  if (size.dynamic) {
    if (policy.includeDynamicSize) {
      decision.value += policy.weightSize;
      decision.reasons.push_back("dynamic-size");
    } else {
      decision.reasons.push_back("dynamic-size-excluded");
    }
    return;
  }

  if (policy.largeAllocationThreshold != 0 &&
      size.estimatedBytes >= policy.largeAllocationThreshold) {
    decision.value += policy.weightSize;
    decision.reasons.push_back("large-allocation");
  }
}

HITMRiskScore scoreSite(const AllocationSite &site,
                        const ScoringContext &context,
                        const HITMRiskPolicy &policy) {
  ScoreDecision decision;
  SizeInfo size = estimateAllocationSize(site, 0);

  if (!isHeapAllocation(site.kind) && !isMMapAllocation(site.kind)) {
    decision.reasons.push_back("not-supported-allocation");
    return {0, false, false, size.dynamic, size.estimatedBytes,
            joinReasons(decision.reasons)};
  }

  addEscapeScore(analyzeEscapes(site), policy, decision);
  addSyncScore(site, context, policy, decision);
  addThreadScore(site, context, policy, decision);
  addSizeScore(size, policy, decision);

  if (!decision.hasEscape)
    decision.reasons.push_back("no-escape");
  if (!decision.hasSyncOrMutable)
    decision.reasons.push_back("no-sync-mutable");

  return {decision.value, decision.hasEscape, decision.hasSyncOrMutable,
          size.dynamic, size.estimatedBytes, joinReasons(decision.reasons)};
}

} // namespace

struct HITMRiskScorer::Impl {
  Impl(Module &module, HITMRiskPolicy scoringPolicy)
      : context(buildContext(module)), policy(std::move(scoringPolicy)) {}

  ScoringContext context;
  HITMRiskPolicy policy;
};

HITMRiskScorer::HITMRiskScorer(Module &module, HITMRiskPolicy policy)
    : impl(std::make_unique<Impl>(module, std::move(policy))) {}

HITMRiskScorer::~HITMRiskScorer() = default;

HITMRiskScorer::HITMRiskScorer(HITMRiskScorer &&) noexcept = default;

HITMRiskScorer &
HITMRiskScorer::operator=(HITMRiskScorer &&) noexcept = default;

HITMRiskScore HITMRiskScorer::score(const AllocationSite &site) const {
  return scoreSite(site, impl->context, impl->policy);
}

bool qualifiesAsHITMRiskSeed(const AllocationSite &site,
                             const HITMRiskScore &score, uint64_t minScore,
                             bool requireEscape, bool requireSync) {
  return isHeapAllocation(site.kind) &&
         (!requireEscape || score.hasEscape) &&
         (!requireSync || score.hasSyncOrMutable) &&
         score.value >= minScore;
}

HITMSeedSelection selectHITMSeeds(Module &module,
                                  ArrayRef<AllocationSite> sites,
                                  const HITMSeedPolicy &policy) {
  auto failConfig = [](const Twine &message) -> void {
    report_fatal_error(Twine("arbiter hotset config: ") + message, false);
  };

  HITMSeedSelection selection;
  selection.records.reserve(sites.size());
  HITMRiskScorer scorer(module, policy.scoring);

  std::unordered_map<uint32_t, size_t> recordBySiteId;
  recordBySiteId.reserve(sites.size());
  for (const AllocationSite &site : sites) {
    HITMSeedDecision record;
    record.site = &site;
    record.score = scorer.score(site);
    recordBySiteId.emplace(site.id, selection.records.size());
    selection.records.push_back(std::move(record));
  }

  SmallVector<StringRef, 16> parts;
  StringRef(policy.explicitSiteIds).split(parts, ',', -1, false);
  std::vector<uint32_t> explicitIds;
  std::unordered_set<uint32_t> seen;
  for (StringRef part : parts) {
    part = part.trim();
    if (part.empty())
      continue;

    uint32_t id = 0;
    if (part.getAsInteger(10, id))
      failConfig(Twine("invalid HITM seed site id '") + part + "'");
    if (seen.insert(id).second)
      explicitIds.push_back(id);
  }

  std::vector<HITMSeedDecision *> candidates;
  if (!explicitIds.empty()) {
    for (uint32_t id : explicitIds) {
      auto recordIt = recordBySiteId.find(id);
      if (recordIt == recordBySiteId.end())
        failConfig(Twine("explicit HITM seed site ") + Twine(id) +
                   " does not exist");

      HITMSeedDecision &record = selection.records[recordIt->second];
      if (!isHeapAllocation(record.site->kind))
        failConfig(Twine("explicit HITM seed site ") + Twine(id) +
                   " is not a heap allocation");
      candidates.push_back(&record);
    }
  } else {
    for (HITMSeedDecision &record : selection.records) {
      if (qualifiesAsHITMRiskSeed(*record.site, record.score,
                                  policy.minScore, policy.requireEscape,
                                  policy.requireSync)) {
        candidates.push_back(&record);
      }
    }
  }

  std::sort(candidates.begin(), candidates.end(),
            [](const HITMSeedDecision *left,
               const HITMSeedDecision *right) {
              if (left->score.value != right->score.value)
                return left->score.value > right->score.value;
              return left->site->id < right->site->id;
            });

  uint32_t groupId = 1;
  for (size_t index = 0; index < candidates.size(); ++index) {
    HITMSeedDecision &record = *candidates[index];
    if (explicitIds.empty() && index >= policy.seedLimit)
      continue;

    record.selected = true;
    record.groupId = groupId++;
  }
  return selection;
}

} // namespace arbiter::llvm::hotset
