#include "arbiter/LLVM/Passes.h"

#include "arbiter/LLVM/AllocationSite.h"
#include "arbiter/LLVM/RewritePlan.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

#include <memory>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

using namespace llvm;

namespace arbiter::llvm {
namespace {

struct FunctionSyncInfo {
  bool atomicRmwOrCmpXchg = false;
  bool atomicOrVolatileStore = false;
  bool lockInlineAsm = false;
};

struct SharedMutableContext {
  DenseMap<const Function *, FunctionSyncInfo> functionSync;
  std::unordered_set<std::string> filesWithSyncMutation;
  SmallPtrSet<const Function *, 16> pthreadWorkerEntries;
  SmallPtrSet<const Function *, 32> pthreadWorkerReachable;
};

struct EscapeSignals {
  bool returns = false;
  bool stores = false;
  bool calls = false;
};

struct SharedMutableDecision {
  uint32_t score = 0;
  bool hasEscape = false;
  bool hasSyncOrMutable = false;
  std::vector<std::string> reasons;
};

bool contains(StringRef value, StringRef needle) {
  return value.find(needle) != StringRef::npos;
}

StringRef calledName(const CallBase &call) {
  const Value *called = call.getCalledOperand()->stripPointerCasts();
  if (const auto *fn = dyn_cast<Function>(called))
    return fn->getName();
  return StringRef();
}

std::string getDebugFile(const DILocation *loc) {
  if (!loc)
    return "";

  StringRef filename = loc->getFilename();
  StringRef directory = loc->getDirectory();
  if (filename.empty())
    return "";
  if (sys::path::is_absolute(filename) || directory.empty())
    return filename.str();

  SmallString<256> path(directory);
  sys::path::append(path, filename);
  return path.str().str();
}

std::string getInstructionFile(const Instruction &inst) {
  DebugLoc debugLoc = inst.getDebugLoc();
  const DILocation *loc = debugLoc ? debugLoc.get() : nullptr;
  return getDebugFile(loc);
}

bool isLockOrCmpXchgInlineAsm(const CallBase &call) {
  const auto *asmValue =
      dyn_cast<InlineAsm>(call.getCalledOperand()->stripPointerCasts());
  if (!asmValue)
    return false;

  StringRef asmText = asmValue->getAsmString();
  return contains(asmText, "lock") || contains(asmText, "cmpxchg");
}

bool isSyncMutation(const Instruction &inst) {
  if (isa<AtomicRMWInst>(inst) || isa<AtomicCmpXchgInst>(inst))
    return true;

  if (const auto *store = dyn_cast<StoreInst>(&inst))
    return store->isAtomic() || store->isVolatile();

  if (const auto *call = dyn_cast<CallBase>(&inst))
    return isLockOrCmpXchgInlineAsm(*call);

  return false;
}

bool isTransparentPointerTransform(const User *user) {
  if (isa<PHINode>(user) || isa<SelectInst>(user))
    return true;

  const auto *op = dyn_cast<Operator>(user);
  if (!op)
    return false;

  switch (op->getOpcode()) {
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

bool callUsesValueAsArg(const CallBase &call, const Value *value) {
  for (const Use &arg : call.args()) {
    if (arg.get() == value)
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
      if (const auto *ret = dyn_cast<ReturnInst>(user)) {
        (void)ret;
        signals.returns = true;
        continue;
      }

      if (const auto *store = dyn_cast<StoreInst>(user)) {
        if (store->getValueOperand() == value)
          signals.stores = true;
        continue;
      }

      if (const auto *call = dyn_cast<CallBase>(user)) {
        if (callUsesValueAsArg(*call, value) && !isIgnoredEscapeCall(*call))
          signals.calls = true;
        continue;
      }

      if (depth >= 6)
        continue;

      if (!isTransparentPointerTransform(user))
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

    for (Instruction &inst : instructions(function)) {
      const auto *call = dyn_cast<CallBase>(&inst);
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
    SharedMutableContext &context) {
  SmallVector<const Function *, 16> worklist;
  for (const Function *worker : context.pthreadWorkerEntries) {
    context.pthreadWorkerReachable.insert(worker);
    worklist.push_back(worker);
  }

  while (!worklist.empty()) {
    const Function *function = worklist.pop_back_val();
    auto it = graph.find(function);
    if (it == graph.end())
      continue;

    for (const Function *callee : it->second) {
      if (context.pthreadWorkerReachable.insert(callee).second)
        worklist.push_back(callee);
    }
  }
}

SharedMutableContext buildContext(Module &module) {
  SharedMutableContext context;

  for (Function &function : module) {
    if (function.isDeclaration())
      continue;

    FunctionSyncInfo syncInfo;
    for (Instruction &inst : instructions(function)) {
      if (isa<AtomicRMWInst>(inst) || isa<AtomicCmpXchgInst>(inst))
        syncInfo.atomicRmwOrCmpXchg = true;
      else if (const auto *store = dyn_cast<StoreInst>(&inst))
        syncInfo.atomicOrVolatileStore |= store->isAtomic() || store->isVolatile();
      else if (const auto *call = dyn_cast<CallBase>(&inst)) {
        syncInfo.lockInlineAsm |= isLockOrCmpXchgInlineAsm(*call);
        if (const Function *startRoutine = getPThreadStartRoutine(*call))
          context.pthreadWorkerEntries.insert(startRoutine);
      }

      if (isSyncMutation(inst)) {
        std::string file = getInstructionFile(inst);
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

bool getConstantInt(Value *value, uint64_t &out) {
  auto *constant = dyn_cast_or_null<ConstantInt>(value);
  if (!constant)
    return false;
  out = constant->getZExtValue();
  return true;
}

bool hasDynamicOrLargeSize(const AllocationSite &site, std::string &reason) {
  CallBase *call = site.call;
  if (!call)
    return false;

  uint64_t size = 0;
  if (site.kind == AllocationKind::Calloc) {
    if (call->arg_size() < 2)
      return false;

    uint64_t count = 0;
    uint64_t elemSize = 0;
    if (!getConstantInt(call->getArgOperand(0), count) ||
        !getConstantInt(call->getArgOperand(1), elemSize)) {
      reason = "dynamic-size";
      return true;
    }

    size = count * elemSize;
  } else {
    if (call->arg_size() < 1)
      return false;

    if (!getConstantInt(call->getArgOperand(0), size)) {
      reason = "dynamic-size";
      return true;
    }
  }

  if (size >= 4096) {
    reason = "large-allocation";
    return true;
  }

  return false;
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

void addEscapeScore(const EscapeSignals &escapes,
                    SharedMutableDecision &decision) {
  if (escapes.returns) {
    decision.score += 3;
    decision.hasEscape = true;
    decision.reasons.push_back("escapes-return");
  }

  if (escapes.stores) {
    decision.score += 3;
    decision.hasEscape = true;
    decision.reasons.push_back("escapes-store");
  }

  if (escapes.calls) {
    decision.score += 2;
    decision.hasEscape = true;
    decision.reasons.push_back("escapes-call");
  }
}

void addSyncScore(const AllocationSite &site, const SharedMutableContext &context,
                  SharedMutableDecision &decision) {
  const Function *function = site.call ? site.call->getFunction() : nullptr;
  bool hasFunctionSync = false;

  if (function) {
    auto syncIt = context.functionSync.find(function);
    if (syncIt != context.functionSync.end()) {
      const FunctionSyncInfo &syncInfo = syncIt->second;
      if (syncInfo.atomicRmwOrCmpXchg) {
        decision.score += 3;
        decision.reasons.push_back("sync-atomic-rmw-or-cmpxchg-same-function");
        hasFunctionSync = true;
      }
      if (syncInfo.atomicOrVolatileStore) {
        decision.score += 2;
        decision.reasons.push_back("sync-atomic-or-volatile-store-same-function");
        hasFunctionSync = true;
      }
      if (syncInfo.lockInlineAsm) {
        decision.score += 2;
        decision.reasons.push_back("sync-inline-asm-same-function");
        hasFunctionSync = true;
      }
    }
  }

  if (hasFunctionSync) {
    decision.hasSyncOrMutable = true;
    return;
  }

  if (!site.file.empty() && context.filesWithSyncMutation.count(site.file)) {
    decision.score += 1;
    decision.hasSyncOrMutable = true;
    decision.reasons.push_back("sync-mutation-same-file");
  }
}

void addThreadScore(const AllocationSite &site,
                    const SharedMutableContext &context,
                    SharedMutableDecision &decision) {
  const Function *function = site.call ? site.call->getFunction() : nullptr;
  if (!function)
    return;

  if (context.pthreadWorkerEntries.count(function)) {
    decision.score += 3;
    decision.reasons.push_back("pthread-worker-entry");
    return;
  }

  if (context.pthreadWorkerReachable.count(function)) {
    decision.score += 2;
    decision.reasons.push_back("pthread-worker-reachable");
  }
}

SharedMutableDecision scoreSharedMutablePattern(
    const AllocationSite &site, const SharedMutableContext &context) {
  SharedMutableDecision decision;

  if (!isHeapAllocation(site.kind)) {
    decision.reasons.push_back("not-heap-allocation");
    return decision;
  }

  addEscapeScore(analyzeEscapes(site), decision);
  addSyncScore(site, context, decision);
  addThreadScore(site, context, decision);

  std::string sizeReason;
  if (hasDynamicOrLargeSize(site, sizeReason)) {
    decision.score += 1;
    decision.reasons.push_back(std::move(sizeReason));
  }

  if (!decision.hasEscape)
    decision.reasons.push_back("no-escape");
  if (!decision.hasSyncOrMutable)
    decision.reasons.push_back("no-sync-mutable");

  return decision;
}

bool isSelected(const AllocationSite &site,
                const SharedMutableDecision &decision) {
  return isHeapAllocation(site.kind) && decision.hasEscape &&
         decision.hasSyncOrMutable &&
         decision.score >= ArbiterSharedMutableMinScore;
}

void emitSharedMutableReport(raw_ostream &os, ArrayRef<AllocationSite> sites,
                             const SharedMutableContext &context) {
  os << "site_id,kind,function,file,line,callee,size_expr,score,selected,"
        "reasons\n";
  for (const AllocationSite &site : sites) {
    SharedMutableDecision decision = scoreSharedMutablePattern(site, context);
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

RewritePlan buildSharedMutableRewritePlan(ArrayRef<AllocationSite> sites,
                                          const SharedMutableContext &context) {
  RewritePlan plan;
  for (const AllocationSite &site : sites) {
    SharedMutableDecision decision = scoreSharedMutablePattern(site, context);
    if (isSelected(site, decision))
      plan.selectHeapAllocation(site.id, joinReasons(decision.reasons));
  }
  return plan;
}

} // namespace

PreservedAnalyses SharedMutableReportPass::run(Module &module,
                                               ModuleAnalysisManager &) {
  std::vector<AllocationSite> sites = collectAllocationSites(module);
  SharedMutableContext context = buildContext(module);

  std::error_code ec;
  std::unique_ptr<raw_fd_ostream> file =
      openFile(ArbiterSharedMutableReportPath, ec);
  if (ec) {
    errs() << "arbiter: failed to open shared-mutable report path "
           << ArbiterSharedMutableReportPath << ": " << ec.message() << "\n";
    return PreservedAnalyses::all();
  }

  raw_ostream &os = file ? *file : outs();
  emitSharedMutableReport(os, sites, context);
  return PreservedAnalyses::all();
}

PreservedAnalyses SharedMutableRewriteExperimentPass::run(
    Module &module, ModuleAnalysisManager &manager) {
  (void)manager;

  std::vector<AllocationSite> sites = collectAllocationSites(module);
  SharedMutableContext context = buildContext(module);
  RewritePlan plan = buildSharedMutableRewritePlan(sites, context);

  bool changed = false;
  changed |= applyHeapRewrites(module, sites, plan);
  return changed ? PreservedAnalyses::none() : PreservedAnalyses::all();
}

} // namespace arbiter::llvm
