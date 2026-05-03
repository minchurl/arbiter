#include "arbiter/Transforms/Passes.h"

#include "mlir/Pass/PassRegistry.h"

using namespace mlir;

namespace mlir::arbiter {
void registerMarkCandidatesPass();
void registerRewriteAllocationsPass();
void registerRewriteDeallocationsPass();
void registerLowerToRuntimePass();
} // namespace mlir::arbiter

void mlir::arbiter::registerArbiterPasses() {
  registerMarkCandidatesPass();
  registerRewriteAllocationsPass();
  registerRewriteDeallocationsPass();
  registerLowerToRuntimePass();
}
