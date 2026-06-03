#include "arbiter/LLVM/Passes.h"

#include "arbiter/LLVM/AllocationSite.h"
#include "arbiter/LLVM/RewritePlan.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

namespace arbiter::llvm {
namespace {

Value *castInteger(IRBuilder<> &builder, Value *value, Type *targetType) {
  if (!value || !value->getType()->isIntegerTy())
    return ConstantInt::get(targetType, 0);
  if (value->getType() == targetType)
    return value;
  return builder.CreateZExtOrTrunc(value, targetType);
}

Value *constantI32(IRBuilder<> &builder, uint32_t value) {
  return ConstantInt::get(builder.getInt32Ty(), value);
}

FunctionCallee getMMapSiteFn(Module &module) {
  LLVMContext &context = module.getContext();
  Type *ptrTy = PointerType::getUnqual(context);
  Type *i64Ty = Type::getInt64Ty(context);
  Type *i32Ty = Type::getInt32Ty(context);
  return module.getOrInsertFunction("arbiter_mmap_site", ptrTy, i64Ty, i32Ty,
                                    i32Ty, i32Ty, i32Ty);
}

FunctionCallee getMUnmapMaybeFn(Module &module) {
  LLVMContext &context = module.getContext();
  Type *ptrTy = PointerType::getUnqual(context);
  Type *i64Ty = Type::getInt64Ty(context);
  Type *i32Ty = Type::getInt32Ty(context);
  return module.getOrInsertFunction("arbiter_munmap_maybe", i32Ty, ptrTy,
                                    i64Ty);
}

bool rewriteMMap(Module &module, const AllocationSite &site) {
  auto *call = dyn_cast<CallInst>(site.call);
  if (!call || call->arg_size() < 4 || !isAnonymousMMap(*call))
    return false;

  IRBuilder<> builder(call);
  Type *i64Ty = builder.getInt64Ty();
  Type *i32Ty = builder.getInt32Ty();

  Value *size = castInteger(builder, call->getArgOperand(1), i64Ty);
  Value *prot = castInteger(builder, call->getArgOperand(2), i32Ty);
  Value *mmapFlags = castInteger(builder, call->getArgOperand(3), i32Ty);
  Value *siteId = constantI32(builder, site.id);
  Value *flags = constantI32(builder, 0);

  CallInst *replacement = builder.CreateCall(
      getMMapSiteFn(module), {size, prot, mmapFlags, siteId, flags});
  replacement->takeName(call);
  call->replaceAllUsesWith(replacement);
  call->eraseFromParent();
  return true;
}

bool rewriteMUnmap(Module &module, const AllocationSite &site) {
  auto *call = dyn_cast<CallInst>(site.call);
  if (!call || call->arg_size() < 2)
    return false;

  IRBuilder<> builder(call);
  Value *ptr = call->getArgOperand(0);
  Value *size =
      castInteger(builder, call->getArgOperand(1), builder.getInt64Ty());
  CallInst *replacement =
      builder.CreateCall(getMUnmapMaybeFn(module), {ptr, size});
  call->replaceAllUsesWith(replacement);
  call->eraseFromParent();
  return true;
}

} // namespace

bool applyMMapRewrites(Module &module, ArrayRef<AllocationSite> sites,
                       const RewritePlan &plan) {
  SmallVector<const AllocationSite *, 16> mmapAllocationsToRewrite;
  SmallVector<const AllocationSite *, 16> munmapSitesToRewrite;

  for (const AllocationSite &site : sites) {
    if (isMMapAllocation(site.kind) && plan.shouldRewriteMMap(site.id))
      mmapAllocationsToRewrite.push_back(&site);
    else if (plan.rewriteMUnmapSites && isMMapDeallocation(site.kind))
      munmapSitesToRewrite.push_back(&site);
  }

  bool changed = false;
  for (const AllocationSite *site : mmapAllocationsToRewrite) {
    if (!site->call || !isAnonymousMMap(*site->call)) {
      errs() << "arbiter: refusing to rewrite non-anonymous mmap site "
             << site->id << "\n";
      continue;
    }
    changed |= rewriteMMap(module, *site);
  }

  if (!changed)
    return false;

  for (const AllocationSite *site : munmapSitesToRewrite)
    changed |= rewriteMUnmap(module, *site);

  return changed;
}
} // namespace arbiter::llvm
