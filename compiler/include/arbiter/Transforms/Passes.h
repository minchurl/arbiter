#ifndef ARBITER_TRANSFORMS_PASSES_H
#define ARBITER_TRANSFORMS_PASSES_H

#include <memory>

#include "mlir/Pass/Pass.h"

namespace mlir::arbiter {

std::unique_ptr<Pass> createSelectAllocationsPass();
std::unique_ptr<Pass> createRewriteAllocationsPass();
std::unique_ptr<Pass> createRewriteDeallocationsPass();
std::unique_ptr<Pass> createLowerToRuntimePass();

void registerArbiterPasses();

} // namespace mlir::arbiter

#endif // ARBITER_TRANSFORMS_PASSES_H
