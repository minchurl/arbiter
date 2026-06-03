#include "arbiter/LLVM/Passes.h"

#include "arbiter/LLVM/AllocationSite.h"
#include "arbiter/LLVM/RewritePlan.h"

#include "llvm/ADT/StringRef.h"
#include "llvm/IR/IRBuilder.h"

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

Value *defaultAlignment(IRBuilder<> &builder) {
  return ConstantInt::get(builder.getInt64Ty(), ArbiterDefaultAlignment);
}

Value *alignmentForCall(IRBuilder<> &builder, CallBase &call) {
  if (call.arg_size() >= 2 && call.getArgOperand(1)->getType()->isIntegerTy())
    return castInteger(builder, call.getArgOperand(1), builder.getInt64Ty());
  return defaultAlignment(builder);
}

FunctionCallee getAllocSiteFn(Module &module) {
  LLVMContext &context = module.getContext();
  Type *ptrTy = PointerType::getUnqual(context);
  Type *i64Ty = Type::getInt64Ty(context);
  Type *i32Ty = Type::getInt32Ty(context);
  return module.getOrInsertFunction("arbiter_alloc_site", ptrTy, i64Ty, i64Ty,
                                    i32Ty, i32Ty);
}

FunctionCallee getCallocSiteFn(Module &module) {
  LLVMContext &context = module.getContext();
  Type *ptrTy = PointerType::getUnqual(context);
  Type *i64Ty = Type::getInt64Ty(context);
  Type *i32Ty = Type::getInt32Ty(context);
  return module.getOrInsertFunction("arbiter_calloc_site", ptrTy, i64Ty, i64Ty,
                                    i64Ty, i32Ty, i32Ty);
}

FunctionCallee getVoidPtrRuntimeFn(Module &module, StringRef name) {
  LLVMContext &context = module.getContext();
  Type *ptrTy = PointerType::getUnqual(context);
  Type *voidTy = Type::getVoidTy(context);
  return module.getOrInsertFunction(name, voidTy, ptrTy);
}

FunctionCallee getDeallocationFn(Module &module, AllocationKind kind) {
  switch (kind) {
  case AllocationKind::CxxDelete:
    return getVoidPtrRuntimeFn(module, "arbiter_cxx_delete_maybe");
  case AllocationKind::CxxDeleteArray:
    return getVoidPtrRuntimeFn(module, "arbiter_cxx_delete_array_maybe");
  default:
    return getVoidPtrRuntimeFn(module, "arbiter_free_maybe");
  }
}

bool rewriteAllocation(Module &module, const AllocationSite &site) {
  auto *call = dyn_cast<CallInst>(site.call);
  if (!call)
    return false;

  IRBuilder<> builder(call);
  Type *i64Ty = builder.getInt64Ty();
  Value *siteId = constantI32(builder, site.id);
  Value *flags = constantI32(builder, 0);

  if (site.kind == AllocationKind::Calloc) {
    if (call->arg_size() < 2)
      return false;
    Value *count = castInteger(builder, call->getArgOperand(0), i64Ty);
    Value *elemSize = castInteger(builder, call->getArgOperand(1), i64Ty);
    Value *align = defaultAlignment(builder);
    CallInst *replacement = builder.CreateCall(
        getCallocSiteFn(module), {count, elemSize, align, siteId, flags});
    replacement->takeName(call);
    call->replaceAllUsesWith(replacement);
    call->eraseFromParent();
    return true;
  }

  if (call->arg_size() < 1)
    return false;

  Value *size = castInteger(builder, call->getArgOperand(0), i64Ty);
  Value *align = alignmentForCall(builder, *call);
  CallInst *replacement =
      builder.CreateCall(getAllocSiteFn(module), {size, align, siteId, flags});
  replacement->takeName(call);
  call->replaceAllUsesWith(replacement);
  call->eraseFromParent();
  return true;
}

bool rewriteDeallocation(Module &module, const AllocationSite &site) {
  auto *call = dyn_cast<CallInst>(site.call);
  if (!call || call->arg_size() < 1)
    return false;

  IRBuilder<> builder(call);
  builder.CreateCall(getDeallocationFn(module, site.kind),
                     {call->getArgOperand(0)});
  call->eraseFromParent();
  return true;
}

} // namespace

bool applyHeapRewrites(Module &module, ArrayRef<AllocationSite> sites,
                       const RewritePlan &plan) {
  bool changed = false;

  for (const AllocationSite &site : sites) {
    if (isHeapAllocation(site.kind) &&
        plan.shouldRewriteHeapAllocation(site.id)) {
      changed |= rewriteAllocation(module, site);
      continue;
    }

    if (plan.rewriteHeapDeallocationSites && isHeapDeallocation(site.kind))
      changed |= rewriteDeallocation(module, site);
  }

  return changed;
}
} // namespace arbiter::llvm
