#include "CompanionAnalysis.h"
#include "HITMSeedOptions.h"
#include "arbiter/LLVM/HITMSeed/Passes.h"
#include "arbiter/LLVM/RewritePlan.h"

#include "llvm/ADT/MapVector.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/Analysis/ScalarEvolution.h"
#include "llvm/Analysis/ScalarEvolutionExpressions.h"
#include "llvm/Analysis/ValueTracking.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/Transforms/Utils/ModuleUtils.h"

#include <set>

using namespace llvm;
namespace arbiter::llvm::hitm_seed {
namespace {
struct PublishedRange {
  GlobalVariable *base = nullptr;
  uint64_t count = 0, stride = 0, offset = 0;
};
bool zeroCounter(Constant *value, Type *type, uint64_t offset,
                 const DataLayout &layout) {
  if (!value || isa<UndefValue>(value) || isa<PoisonValue>(value))
    return false;
  if (type->isIntegerTy(64))
    return offset == 0 && value->isNullValue();
  if (auto *structure = dyn_cast<StructType>(type)) {
    auto *shape = layout.getStructLayout(structure);
    if (offset >= shape->getSizeInBytes())
      return false;
    unsigned index = shape->getElementContainingOffset(offset);
    return zeroCounter(value->getAggregateElement(index),
                       structure->getElementType(index),
                       offset - shape->getElementOffset(index), layout);
  }
  if (auto *array = dyn_cast<ArrayType>(type)) {
    uint64_t stride = layout.getTypeAllocSize(array->getElementType());
    if (!stride || offset / stride >= array->getNumElements())
      return false;
    return zeroCounter(value->getAggregateElement(unsigned(offset / stride)),
                       array->getElementType(), offset % stride, layout);
  }
  return false;
}
PublishedRange counterRange(StoreInst *store, const DataLayout &layout) {
  if (!store)
    return {};
  Value *pointer = store->getPointerOperand();
  auto *global = dyn_cast<GlobalVariable>(getUnderlyingObject(pointer));
  if (!global || !global->hasInitializer())
    return {};
  if (pointer == global && global->getValueType()->isIntegerTy(64))
    return global->getInitializer()->isNullValue()
               ? PublishedRange{global, 1, 8, 0}
               : PublishedRange{};
  auto *array = dyn_cast<ArrayType>(global->getValueType());
  auto *gep = dyn_cast<GetElementPtrInst>(pointer);
  if (!array || !gep || gep->getPointerOperand() != global ||
      array->getNumElements() > 65536)
    return {};
  uint64_t stride = layout.getTypeAllocSize(array->getElementType());
  MapVector<Value *, APInt> variables;
  APInt offset(64, 0);
  if (!gep->collectOffset(layout, 64, variables, offset) ||
      variables.size() != 1 || variables.begin()->second != stride ||
      offset.isNegative() || offset.getZExtValue() + 8 > stride || stride % 8 ||
      offset.getZExtValue() % 8)
    return {};
  for (uint64_t i = 0; i < array->getNumElements(); ++i)
    if (!zeroCounter(global->getInitializer(), global->getValueType(),
                     i * stride + offset.getZExtValue(), layout))
      return {};
  return {global, array->getNumElements(), stride, offset.getZExtValue()};
}
// Reuse a published induction counter only for the structural pattern
// {{1,+,batch}<outer>,+,1}<inner>. Its address must be process-lifetime global
// storage, invariant throughout the outer loop, with a dominating atomic store.
// This avoids names/RCU-specific knowledge; other loops get injected counters.
StoreInst *publishedProgress(Loop *loop, unsigned batch, ScalarEvolution &scev,
                             DominatorTree &dom) {
  Loop *outer = loop->getParentLoop();
  if (!batch || !outer || outer->getParentLoop() || !outer->getLoopPreheader())
    return nullptr;
  StoreInst *found = nullptr;
  for (BasicBlock *block : loop->blocks())
    for (Instruction &instruction : *block) {
      auto *store = dyn_cast<StoreInst>(&instruction);
      if (!store || !store->isAtomic() || store->getAlign() < Align(8) ||
          !store->getValueOperand()->getType()->isIntegerTy(64) ||
          !dom.dominates(store->getParent(), loop->getLoopLatch()) ||
          !outer->isLoopInvariant(store->getPointerOperand()))
        continue;
      auto *global = dyn_cast<GlobalVariable>(
          getUnderlyingObject(store->getPointerOperand()));
      if (!global || global->isThreadLocal() || global->isDeclaration())
        continue;
      if (auto *pointer = dyn_cast<Instruction>(store->getPointerOperand()))
        if (!dom.dominates(pointer, outer->getLoopPreheader()->getTerminator()))
          continue;
      auto *inner =
          dyn_cast<SCEVAddRecExpr>(scev.getSCEV(store->getValueOperand()));
      if (!inner || inner->getLoop() != loop || !inner->isAffine() ||
          !inner->getStepRecurrence(scev)->isOne())
        continue;
      auto *start = dyn_cast<SCEVAddRecExpr>(inner->getStart());
      if (!start || start->getLoop() != outer || !start->isAffine() ||
          !start->getStart()->isOne() ||
          start->getStepRecurrence(scev) !=
              scev.getConstant(store->getValueOperand()->getType(), batch))
        continue;
      if (found)
        return nullptr;
      found = store;
    }
  return found;
}
} // namespace
PreservedAnalyses AdaptiveExperimentPass::run(Module &module,
                                              ModuleAnalysisManager &manager) {
  // Experimental, single progress domain. A missed/ambiguous candidate leaves
  // the existing seed rewrite intact; no benchmark names or input arguments.
  auto sites = collectAllocationSites(module);
  auto seeds = selectHITMSeeds(module, sites, hitmSeedPolicyFromOptions());
  RewritePlan plan;
  for (const auto &record : seeds.records)
    if (record.selected)
      plan.selectHeapAllocation(record.site->id, record.score.reasons);
  auto candidates = discoverLoopCompanions(module, seeds);
  std::set<const BasicBlock *> headers;
  for (const auto &candidate : candidates)
    headers.insert(candidate.loopHeader);
  bool instrumented = false;
  if (headers.size() == 1 && *headers.begin()) {
    auto *header = const_cast<BasicBlock *>(*headers.begin());
    Function &function = *header->getParent();
    auto &fam = manager.getResult<FunctionAnalysisManagerModuleProxy>(module)
                    .getManager();
    auto &loops = fam.getResult<LoopAnalysis>(function);
    Loop *loop = loops.getLoopFor(header);
    BasicBlock *latch = loop ? loop->getLoopLatch() : nullptr;
    // A single latch/exit avoids counting early exits or retry-only paths.
    if (latch && loop->getExitingBlock() == latch) {
      auto &scev = fam.getResult<ScalarEvolutionAnalysis>(function);
      unsigned batch = scev.getSmallConstantTripCount(loop);
      BasicBlock *exit = loop->getUniqueExitBlock();
      if (!exit || !loop->hasDedicatedExits())
        batch = 0;
      IRBuilder<> builder(batch ? &*exit->getFirstInsertionPt()
                                : latch->getTerminator());
      auto &dom = fam.getResult<DominatorTreeAnalysis>(function);
      StoreInst *published = publishedProgress(loop, batch, scev, dom);
      auto range = counterRange(published, module.getDataLayout());
      if (!range.base) {
        // Register once on function entry, then publish progress without an
        // out-of-line call on the work path. One worker writes each padded
        // slot.
        IRBuilder<> entry(&*function.getEntryBlock().getFirstInsertionPt());
        auto counter = module.getOrInsertFunction("arbiter_adaptive_counter",
                                                  entry.getPtrTy());
        Value *slot = entry.CreateCall(counter);
        auto *value = builder.CreateLoad(builder.getInt64Ty(), slot);
        value->setAtomic(AtomicOrdering::Monotonic);
        value->setAlignment(Align(8));
        auto *update = builder.CreateStore(
            builder.CreateAdd(value, builder.getInt64(batch ? batch : 1)),
            slot);
        update->setAtomic(AtomicOrdering::Monotonic);
        update->setAlignment(Align(8));
      }
      auto *ctor = Function::Create(
          FunctionType::get(builder.getVoidTy(), false),
          GlobalValue::InternalLinkage, "arbiter.adaptive.init", module);
      IRBuilder<> init(BasicBlock::Create(module.getContext(), "entry", ctor));
      auto registration = module.getOrInsertFunction(
          "arbiter_adaptive_register", init.getVoidTy(), init.getInt32Ty());
      std::set<uint32_t> registered;
      for (const auto &candidate : candidates)
        if (registered.insert(candidate.companion).second) {
          plan.selectHeapAllocation(candidate.companion, "adaptive-companion");
          init.CreateCall(registration, init.getInt32(candidate.companion));
        }
      if (range.base) {
        auto observe = module.getOrInsertFunction(
            "arbiter_adaptive_observe_range", init.getVoidTy(), init.getPtrTy(),
            init.getInt64Ty(), init.getInt64Ty());
        Value *start = init.CreateGEP(init.getInt8Ty(), range.base,
                                      init.getInt64(range.offset));
        init.CreateCall(observe, {start, init.getInt64(range.count),
                                  init.getInt64(range.stride)});
      }
      init.CreateRetVoid();
      appendToGlobalCtors(module, ctor, 65534);
      errs() << "arbiter-adaptive-instrument function=" << function.getName()
             << " batch=" << (batch ? batch : 1) << " progress="
             << (range.base ? "published-induction-range" : "injected")
             << " companions=" << registered.size() << '\n';
      instrumented = true;
    }
  }
  bool changed = applyHeapRewrites(module, sites, plan);
  return changed || instrumented ? PreservedAnalyses::none()
                                 : PreservedAnalyses::all();
}
} // namespace arbiter::llvm::hitm_seed
