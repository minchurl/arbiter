#include "arbiter/Transforms/Passes.h"

#include "mlir/Dialect/MemRef/IR/MemRef.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Builders.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassRegistry.h"

using namespace mlir;

namespace {

class MarkCandidatesPass
    : public PassWrapper<MarkCandidatesPass, OperationPass<ModuleOp>> {
public:
  MLIR_DEFINE_EXPLICIT_INTERNAL_INLINE_TYPE_ID(MarkCandidatesPass)

  StringRef getArgument() const final { return "arbiter-mark-candidates"; }
  StringRef getDescription() const final {
    return "Mark eligible allocation sites as Arbiter placement candidates";
  }

  void runOnOperation() final {
    MLIRContext *context = &getContext();
    UnitAttr candidate = UnitAttr::get(context);
    StringAttr target = StringAttr::get(context, "remote");

    getOperation().walk([&](memref::AllocOp alloc) {
      alloc->setAttr("arbiter.candidate", candidate);
      alloc->setAttr("arbiter.target", target);
    });
  }
};

} // namespace

namespace mlir::arbiter {
void registerMarkCandidatesPass() {
  static PassRegistration<MarkCandidatesPass> pass;
}
} // namespace mlir::arbiter

std::unique_ptr<Pass> mlir::arbiter::createMarkCandidatesPass() {
  return std::make_unique<MarkCandidatesPass>();
}
