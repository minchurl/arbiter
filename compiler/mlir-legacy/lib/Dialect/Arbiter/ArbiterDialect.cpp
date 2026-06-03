#include "arbiter/Dialect/Arbiter/IR/ArbiterDialect.h"
#include "arbiter/Dialect/Arbiter/IR/ArbiterOps.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "mlir/IR/OpImplementation.h"

using namespace mlir;
using namespace mlir::arbiter;

#include "arbiter/Dialect/Arbiter/IR/ArbiterOpsDialect.cpp.inc"

void ArbiterDialect::initialize() {
  addOperations<
#define GET_OP_LIST
#include "arbiter/Dialect/Arbiter/IR/ArbiterOps.cpp.inc"
      >();
}

#define GET_OP_CLASSES
#include "arbiter/Dialect/Arbiter/IR/ArbiterOps.cpp.inc"

void mlir::arbiter::registerArbiterDialect(DialectRegistry &registry) {
  registry.insert<ArbiterDialect>();
}
