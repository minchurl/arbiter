#include "arbiter/Transforms/Passes.h"

#include "arbiter/Dialect/Arbiter/IR/ArbiterOps.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVM.h"
#include "mlir/Conversion/LLVMCommon/ConversionTarget.h"
#include "mlir/Conversion/LLVMCommon/MemRefBuilder.h"
#include "mlir/Conversion/LLVMCommon/Pattern.h"
#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Conversion/MemRefToLLVM/MemRefToLLVM.h"
#include "mlir/Dialect/LLVMIR/FunctionCallUtils.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassRegistry.h"
#include "mlir/Transforms/DialectConversion.h"

using namespace mlir;

namespace {

constexpr uint64_t kDefaultAlignment = 64;
constexpr llvm::StringLiteral kAllocFnName = "arbiter_alloc";
constexpr llvm::StringLiteral kDeallocFnName = "arbiter_dealloc";

FailureOr<LLVM::LLVMFuncOp> lookupOrCreateArbiterAllocFn(OpBuilder &builder,
                                                         Operation *module,
                                                         Type i64Type,
                                                         Type ptrType) {
  return LLVM::lookupOrCreateFn(builder, module, kAllocFnName,
                                {i64Type, i64Type}, ptrType);
}

FailureOr<LLVM::LLVMFuncOp> lookupOrCreateArbiterDeallocFn(OpBuilder &builder,
                                                           Operation *module,
                                                           Type ptrType,
                                                           Type voidType) {
  return LLVM::lookupOrCreateFn(builder, module, kDeallocFnName, {ptrType},
                                voidType);
}

class AllocOpLowering : public ConvertOpToLLVMPattern<arbiter::AllocOp> {
public:
  using ConvertOpToLLVMPattern<arbiter::AllocOp>::ConvertOpToLLVMPattern;

  LogicalResult
  matchAndRewrite(arbiter::AllocOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    Location loc = op.getLoc();
    auto memRefType = dyn_cast<MemRefType>(op.getResult().getType());
    if (!memRefType)
      return op.emitError(
          "arbiter.alloc lowering only supports ranked memrefs");

    if (!isConvertibleAndHasIdentityMaps(memRefType))
      return op.emitError(
          "arbiter.alloc lowering only supports identity layout maps");

    if (!op.getSymbolOperands().empty())
      return op.emitError(
          "arbiter.alloc lowering does not support symbol operands");

    ModuleOp module = op->getParentOfType<ModuleOp>();
    if (!module)
      return op.emitError("expected parent module");

    Type i64Type = rewriter.getI64Type();
    Type ptrType = getPtrType();
    FailureOr<LLVM::LLVMFuncOp> allocFn = lookupOrCreateArbiterAllocFn(
        rewriter, module.getOperation(), i64Type, ptrType);
    if (failed(allocFn))
      return op.emitError(
          "failed to create or reuse arbiter_alloc declaration");

    SmallVector<Value> sizes;
    SmallVector<Value> strides;
    Value sizeBytes;
    getMemRefDescriptorSizes(loc, memRefType, adaptor.getDynamicSizes(),
                             rewriter, sizes, strides, sizeBytes,
                             /*sizeInBytes=*/true);

    uint64_t alignment = op.getAlignment().value_or(kDefaultAlignment);
    Value alignmentValue = rewriter.create<LLVM::ConstantOp>(
        loc, i64Type, static_cast<int64_t>(alignment));

    auto call = rewriter.create<LLVM::CallOp>(
        loc, *allocFn, ValueRange{sizeBytes, alignmentValue});
    Value runtimePtr = call.getResult();

    MemRefDescriptor descriptor = createMemRefDescriptor(
        loc, memRefType, runtimePtr, runtimePtr, sizes, strides, rewriter);

    rewriter.replaceOp(op, {static_cast<Value>(descriptor)});
    return success();
  }
};

class DeallocOpLowering : public ConvertOpToLLVMPattern<arbiter::DeallocOp> {
public:
  using ConvertOpToLLVMPattern<arbiter::DeallocOp>::ConvertOpToLLVMPattern;

  LogicalResult
  matchAndRewrite(arbiter::DeallocOp op, OpAdaptor adaptor,
                  ConversionPatternRewriter &rewriter) const override {
    auto memRefType = dyn_cast<MemRefType>(op.getMemref().getType());
    if (!memRefType)
      return op.emitError(
          "arbiter.dealloc lowering only supports ranked memrefs");

    if (!isConvertibleAndHasIdentityMaps(memRefType))
      return op.emitError(
          "arbiter.dealloc lowering only supports identity layout maps");

    ModuleOp module = op->getParentOfType<ModuleOp>();
    if (!module)
      return op.emitError("expected parent module");

    Type ptrType = getPtrType();
    Type voidType = getVoidType();
    FailureOr<LLVM::LLVMFuncOp> deallocFn = lookupOrCreateArbiterDeallocFn(
        rewriter, module.getOperation(), ptrType, voidType);
    if (failed(deallocFn))
      return op.emitError(
          "failed to create or reuse arbiter_dealloc declaration");

    MemRefDescriptor descriptor(adaptor.getMemref());
    Value allocatedPtr = descriptor.allocatedPtr(rewriter, op.getLoc());
    rewriter.create<LLVM::CallOp>(op.getLoc(), *deallocFn,
                                  ValueRange{allocatedPtr});
    rewriter.eraseOp(op);
    return success();
  }
};

class LowerToRuntimePass
    : public PassWrapper<LowerToRuntimePass, OperationPass<ModuleOp>> {
public:
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(LowerToRuntimePass)

  StringRef getArgument() const final { return "arbiter-lower-to-runtime"; }

  StringRef getDescription() const final {
    return "Lower Arbiter allocation operations to runtime allocator calls";
  }

  void runOnOperation() final {
    ModuleOp module = getOperation();
    MLIRContext *context = module.getContext();

    LowerToLLVMOptions options(context);
    LLVMTypeConverter typeConverter(context, options);
    RewritePatternSet patterns(context);
    SymbolTableCollection symbolTables;

    patterns.add<AllocOpLowering, DeallocOpLowering>(typeConverter);
    arith::populateArithToLLVMConversionPatterns(typeConverter, patterns);
    populateFuncToLLVMConversionPatterns(typeConverter, patterns);
    populateFinalizeMemRefToLLVMConversionPatterns(typeConverter, patterns,
                                                   &symbolTables);

    LLVMConversionTarget target(*context);
    target.addLegalOp<ModuleOp>();
    target.addIllegalOp<arbiter::AllocOp, arbiter::DeallocOp>();

    if (failed(applyFullConversion(module, target, std::move(patterns))))
      signalPassFailure();
  }
};

} // namespace

namespace mlir::arbiter {

void registerLowerToRuntimePass() {
  static PassRegistration<LowerToRuntimePass> pass;
}

std::unique_ptr<Pass> createLowerToRuntimePass() {
  return std::make_unique<LowerToRuntimePass>();
}

} // namespace mlir::arbiter
