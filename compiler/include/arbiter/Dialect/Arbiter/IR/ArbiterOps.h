#ifndef ARBITER_DIALECT_ARBITER_IR_ARBITEROPS_H
#define ARBITER_DIALECT_ARBITER_IR_ARBITEROPS_H

#include "arbiter/Dialect/Arbiter/IR/ArbiterDialect.h"

#include "mlir/Bytecode/BytecodeOpInterface.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/OpDefinition.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"

#define GET_OP_CLASSES
#include "arbiter/Dialect/Arbiter/IR/ArbiterOps.h.inc"

#endif // ARBITER_DIALECT_ARBITER_IR_ARBITEROPS_H
