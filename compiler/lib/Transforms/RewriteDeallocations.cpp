#include "arbiter/Transforms/Passes.h"

#include "arbiter/Dialect/Arbiter/IR/ArbiterOps.h"
#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassRegistry.h"

using namespace mlir;

namespace {

class RewriteDeallocationsPass
    : public PassWrapper<RewriteDeallocationsPass, OperationPass<ModuleOp>> {
public:
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(RewriteDeallocationsPass)

  StringRef getArgument() const final {
    return "arbiter-rewrite-deallocations";
  }
  StringRef getDescription() const final {
    return "Rewrite matching memref.dealloc operations into arbiter.dealloc";
  }

  void runOnOperation() final {
    SmallVector<memref::DeallocOp> deallocs;
    getOperation().walk([&](memref::DeallocOp dealloc) {
      if (dealloc.getMemref().getDefiningOp<arbiter::AllocOp>())
        deallocs.push_back(dealloc);
    });

    for (memref::DeallocOp dealloc : deallocs)
      rewriteDealloc(dealloc);
  }

private:
  void rewriteDealloc(memref::DeallocOp dealloc) {
    auto alloc = dealloc.getMemref().getDefiningOp<arbiter::AllocOp>();
    if (!alloc)
      return;

    OpBuilder builder(dealloc);
    builder.create<arbiter::DeallocOp>(dealloc.getLoc(), dealloc.getMemref());
    dealloc.erase();
  }
};

} // namespace

namespace mlir::arbiter {
void registerRewriteDeallocationsPass() {
  static PassRegistration<RewriteDeallocationsPass> pass;
}
} // namespace mlir::arbiter

std::unique_ptr<Pass> mlir::arbiter::createRewriteDeallocationsPass() {
  return std::make_unique<RewriteDeallocationsPass>();
}
