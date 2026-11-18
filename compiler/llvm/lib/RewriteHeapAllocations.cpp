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

FunctionCallee getAllocSiteFn(Module &module, StringRef name) {
  LLVMContext &context = module.getContext();
  Type *ptrTy = PointerType::getUnqual(context);
  Type *i64Ty = Type::getInt64Ty(context);
  Type *i32Ty = Type::getInt32Ty(context);
  return module.getOrInsertFunction(name, ptrTy, i64Ty, i64Ty, i32Ty, i32Ty);
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

FunctionCallee getVoidPtrI64RuntimeFn(Module &module, StringRef name) {
  LLVMContext &context = module.getContext();
  Type *ptrTy = PointerType::getUnqual(context);
  Type *i64Ty = Type::getInt64Ty(context);
  Type *voidTy = Type::getVoidTy(context);
  return module.getOrInsertFunction(name, voidTy, ptrTy, i64Ty);
}

FunctionCallee getVoidPtrI64I64RuntimeFn(Module &module, StringRef name) {
  LLVMContext &context = module.getContext();
  Type *ptrTy = PointerType::getUnqual(context);
  Type *i64Ty = Type::getInt64Ty(context);
  Type *voidTy = Type::getVoidTy(context);
  return module.getOrInsertFunction(name, voidTy, ptrTy, i64Ty, i64Ty);
}

bool replaceAllocationCall(IRBuilder<> &builder, CallBase &call,
                           FunctionCallee target, ArrayRef<Value *> args) {
  SmallVector<OperandBundleDef, 1> bundles;
  call.getOperandBundlesAsDefs(bundles);
  CallBase *replacement;
  if (auto *invoke = dyn_cast<InvokeInst>(&call))
    replacement = builder.CreateInvoke(target, invoke->getNormalDest(),
                                       invoke->getUnwindDest(), args, bundles);
  else
    replacement = builder.CreateCall(target, args, bundles);
  replacement->setDebugLoc(call.getDebugLoc());
  replacement->takeName(&call);
  call.replaceAllUsesWith(replacement);
  call.eraseFromParent();
  return true;
}

bool rewriteAllocation(Module &module, const AllocationSite &site) {
  CallBase *call = site.call;
  if (!isa<CallInst>(call) && !isa<InvokeInst>(call))
    return false;

  IRBuilder<> builder(call);
  Type *i64Ty = builder.getInt64Ty();
  Value *siteId = constantI32(builder, site.id);
  Value *reserved = constantI32(builder, 0);

  if (site.kind == AllocationKind::Calloc) {
    if (call->arg_size() < 2)
      return false;
    Value *count = castInteger(builder, call->getArgOperand(0), i64Ty);
    Value *elemSize = castInteger(builder, call->getArgOperand(1), i64Ty);
    Value *align = defaultAlignment(builder);
    return replaceAllocationCall(builder, *call, getCallocSiteFn(module),
                                 {count, elemSize, align, siteId, reserved});
  }

  if (call->arg_size() < 1)
    return false;
  StringRef helper = "arbiter_alloc_site";
  if (site.kind == AllocationKind::CxxNew ||
      site.kind == AllocationKind::CxxNewArray) {
    // Preserve custom/placement overloads; only standard Itanium new forms
    // have the size/alignment and failure contracts understood by the runtime.
    StringRef suffix = StringRef(site.callee).drop_front(5);
    if (!suffix.empty() && suffix != "St11align_val_t" &&
        suffix != "RKSt9nothrow_t" && suffix != "St11align_val_tRKSt9nothrow_t")
      return false;
    helper = suffix.contains("nothrow_t") ? "arbiter_new_nothrow_site"
                                          : "arbiter_new_site";
  }
  Value *size = castInteger(builder, call->getArgOperand(0), i64Ty);
  Value *align = alignmentForCall(builder, *call);
  return replaceAllocationCall(builder, *call, getAllocSiteFn(module, helper),
                               {size, align, siteId, reserved});
}

bool rewriteDeallocation(Module &module, const AllocationSite &site) {
  auto *call = dyn_cast<CallInst>(site.call);
  if (!call || call->arg_size() < 1)
    return false;

  IRBuilder<> builder(call);
  Value *ptr = call->getArgOperand(0);
  Type *i64Ty = builder.getInt64Ty();

  if (site.kind == AllocationKind::Free) {
    builder.CreateCall(getVoidPtrRuntimeFn(module, "arbiter_free_maybe"),
                       {ptr});
  } else if (site.callee == "_ZdlPv" || site.callee == "_ZdaPv") {
    StringRef helper = site.kind == AllocationKind::CxxDelete
                           ? "arbiter_cxx_delete_maybe"
                           : "arbiter_cxx_delete_array_maybe";
    builder.CreateCall(getVoidPtrRuntimeFn(module, helper), {ptr});
  } else if (site.callee == "_ZdlPvm" || site.callee == "_ZdaPvm") {
    if (call->arg_size() < 2)
      return false;
    StringRef helper = site.kind == AllocationKind::CxxDelete
                           ? "arbiter_cxx_delete_sized_maybe"
                           : "arbiter_cxx_delete_array_sized_maybe";
    Value *size = castInteger(builder, call->getArgOperand(1), i64Ty);
    builder.CreateCall(getVoidPtrI64RuntimeFn(module, helper), {ptr, size});
  } else if (site.callee == "_ZdlPvSt11align_val_t" ||
             site.callee == "_ZdaPvSt11align_val_t") {
    if (call->arg_size() < 2)
      return false;
    StringRef helper = site.kind == AllocationKind::CxxDelete
                           ? "arbiter_cxx_delete_aligned_maybe"
                           : "arbiter_cxx_delete_array_aligned_maybe";
    Value *align = castInteger(builder, call->getArgOperand(1), i64Ty);
    builder.CreateCall(getVoidPtrI64RuntimeFn(module, helper), {ptr, align});
  } else if (site.callee == "_ZdlPvmSt11align_val_t" ||
             site.callee == "_ZdaPvmSt11align_val_t") {
    if (call->arg_size() < 3)
      return false;
    StringRef helper = site.kind == AllocationKind::CxxDelete
                           ? "arbiter_cxx_delete_sized_aligned_maybe"
                           : "arbiter_cxx_delete_array_sized_aligned_maybe";
    Value *size = castInteger(builder, call->getArgOperand(1), i64Ty);
    Value *align = castInteger(builder, call->getArgOperand(2), i64Ty);
    builder.CreateCall(getVoidPtrI64I64RuntimeFn(module, helper),
                       {ptr, size, align});
  } else {
    // Placement and implementation-specific delete overloads must retain
    // their original ABI rather than being collapsed to delete(void *).
    return false;
  }
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
