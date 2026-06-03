#ifndef ARBITER_DIALECT_ARBITER_IR_ARBITERDIALECT_H
#define ARBITER_DIALECT_ARBITER_IR_ARBITERDIALECT_H

#include "mlir/IR/Dialect.h"
#include "mlir/IR/DialectRegistry.h"

#include "arbiter/Dialect/Arbiter/IR/ArbiterOpsDialect.h.inc"

namespace mlir::arbiter {
void registerArbiterDialect(DialectRegistry &registry);
} // namespace mlir::arbiter

#endif // ARBITER_DIALECT_ARBITER_IR_ARBITERDIALECT_H
