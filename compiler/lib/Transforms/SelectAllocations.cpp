#include "arbiter/Transforms/Passes.h"

#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassRegistry.h"

using namespace mlir;

namespace {

class SelectAllocationsPass
    : public PassWrapper<SelectAllocationsPass, OperationPass<ModuleOp>> {
public:
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(SelectAllocationsPass)

  StringRef getArgument() const final { return "arbiter-select-allocations"; }
  StringRef getDescription() const final {
    return "Select allocation sites for Arbiter placement";
  }

  void runOnOperation() final {
    MLIRContext *context = &getContext();
    UnitAttr selected = UnitAttr::get(context);

    getOperation().walk([&](memref::AllocOp alloc) {
      alloc->setAttr("arbiter.select", selected);
    });
  }
};

} // namespace

namespace mlir::arbiter {
void registerSelectAllocationsPass() {
  static PassRegistration<SelectAllocationsPass> pass;
}
} // namespace mlir::arbiter

std::unique_ptr<Pass> mlir::arbiter::createSelectAllocationsPass() {
  return std::make_unique<SelectAllocationsPass>();
}
