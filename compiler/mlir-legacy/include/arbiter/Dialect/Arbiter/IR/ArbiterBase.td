#ifndef ARBITER_DIALECT_ARBITER_IR_ARBITERBASE
#define ARBITER_DIALECT_ARBITER_IR_ARBITERBASE

include "mlir/IR/OpBase.td"

def Arbiter_Dialect : Dialect {
  let name = "arbiter";
  let cppNamespace = "::mlir::arbiter";
  let summary = "Arbiter allocation placement dialect";
  let description = [{
    The Arbiter dialect represents allocation placement decisions between
    selection/rewrite passes and lowerings to runtime allocator calls.
  }];
}

class Arbiter_Op<string mnemonic, list<Trait> traits = []>
    : Op<Arbiter_Dialect, mnemonic, traits>;

#endif // ARBITER_DIALECT_ARBITER_IR_ARBITERBASE
