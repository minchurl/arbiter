#include "arbiter/Transforms/Passes.h"

#include "arbiter/Dialect/Arbiter/IR/ArbiterOps.h"
#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassRegistry.h"

using namespace mlir;

namespace {

class RewriteAllocationsPass
    : public PassWrapper<RewriteAllocationsPass, OperationPass<ModuleOp>> {
public:
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(RewriteAllocationsPass)

  StringRef getArgument() const final { return "arbiter-rewrite-allocations"; }
  StringRef getDescription() const final {
    return "Rewrite marked memref.alloc operations into arbiter.alloc";
  }

  void runOnOperation() final {
    SmallVector<memref::AllocOp> allocs;
    getOperation().walk([&](memref::AllocOp alloc) {
      if (alloc->hasAttr("arbiter.candidate"))
        allocs.push_back(alloc);
    });

    for (memref::AllocOp alloc : allocs)
      rewriteAlloc(alloc);
  }

private:
  void rewriteAlloc(memref::AllocOp alloc) {
    OpBuilder builder(alloc);
    StringAttr target = alloc->getAttrOfType<StringAttr>("arbiter.target");
    if (!target)
      target = builder.getStringAttr("remote");

    IntegerAttr alignment = alloc->getAttrOfType<IntegerAttr>("alignment");
    auto arbiterAlloc = builder.create<arbiter::AllocOp>(
        alloc.getLoc(), alloc.getType(), alloc.getDynamicSizes(),
        alloc.getSymbolOperands(), target, alignment);
    alloc.getResult().replaceAllUsesWith(arbiterAlloc.getResult());
    alloc.erase();
  }
};

} // namespace

namespace mlir::arbiter {
void registerRewriteAllocationsPass() {
  static PassRegistration<RewriteAllocationsPass> pass;
}
} // namespace mlir::arbiter

std::unique_ptr<Pass> mlir::arbiter::createRewriteAllocationsPass() {
  return std::make_unique<RewriteAllocationsPass>();
}
