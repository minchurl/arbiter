#include "arbiter/Transforms/Passes.h"

#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassRegistry.h"

using namespace mlir;

namespace {

bool isInsideParallel(Operation *op) {
  return op->getParentOfType<scf::ParallelOp>() != nullptr;
}

bool shouldSelectObject(memref::AllocOp alloc) {
  for (Operation *user : alloc.getResult().getUsers()) {
    if (isa<memref::StoreOp>(user) && isInsideParallel(user))
      return true;
  }
  return false;
}

class SelectObjectsPass
    : public PassWrapper<SelectObjectsPass, OperationPass<ModuleOp>> {
public:
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(SelectObjectsPass)

  StringRef getArgument() const final { return "arbiter-select-objects"; }
  StringRef getDescription() const final {
    return "Select memory objects for Arbiter placement";
  }

  void runOnOperation() final {
    MLIRContext *context = &getContext();
    UnitAttr selected = UnitAttr::get(context);

    getOperation().walk([&](memref::AllocOp alloc) {
      if (shouldSelectObject(alloc))
        alloc->setAttr("arbiter.select", selected);
    });
  }
};

} // namespace

namespace mlir::arbiter {
void registerSelectObjectsPass() {
  static PassRegistration<SelectObjectsPass> pass;
}
} // namespace mlir::arbiter

std::unique_ptr<Pass> mlir::arbiter::createSelectObjectsPass() {
  return std::make_unique<SelectObjectsPass>();
}
