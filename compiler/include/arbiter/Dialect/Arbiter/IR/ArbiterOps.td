#ifndef ARBITER_DIALECT_ARBITER_IR_ARBITEROPS
#define ARBITER_DIALECT_ARBITER_IR_ARBITEROPS

include "arbiter/Dialect/Arbiter/IR/ArbiterBase.td"
include "mlir/IR/CommonAttrConstraints.td"
include "mlir/IR/CommonTypeConstraints.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

def Arbiter_AllocOp : Arbiter_Op<"alloc", [AttrSizedOperandSegments]> {
  let summary = "allocation with an Arbiter placement policy";
  let description = [{
    `arbiter.alloc` is the backend-independent allocation operation produced
    after candidate selection. It keeps the original memref type and carries
    placement metadata that later lowerings can translate into runtime calls
    such as `arbiter_alloc`.
  }];

  let arguments = (ins Variadic<Index>:$dynamicSizes,
                       Variadic<Index>:$symbolOperands,
                       OptionalAttr<StrAttr>:$target,
                       ConfinedAttr<OptionalAttr<I64Attr>,
                                    [IntMinValue<0>]>:$alignment);
  let results = (outs Res<AnyMemRef, "",
                          [MemAlloc<DefaultResource, 0, FullEffect>]>:$memref);

  let builders = [
    OpBuilder<(ins "MemRefType":$memrefType,
                  "ValueRange":$dynamicSizes,
                  "ValueRange":$symbolOperands,
                  CArg<"StringAttr", "{}">:$target,
                  CArg<"IntegerAttr", "{}">:$alignment), [{
      $_state.types.push_back(memrefType);
      $_state.addOperands(dynamicSizes);
      $_state.addOperands(symbolOperands);
      $_state.addAttribute(getOperandSegmentSizeAttr(),
          $_builder.getDenseI32ArrayAttr({
              static_cast<int32_t>(dynamicSizes.size()),
              static_cast<int32_t>(symbolOperands.size())}));
      if (target)
        $_state.addAttribute(getTargetAttrName($_state.name), target);
      if (alignment)
        $_state.addAttribute(getAlignmentAttrName($_state.name), alignment);
    }]>
  ];

  let assemblyFormat = [{
    `(` $dynamicSizes `)` (`` `[` $symbolOperands^ `]`)? attr-dict `:`
    type($memref)
  }];

  let extraClassDeclaration = [{
    MemRefType getType() {
      return ::llvm::cast<MemRefType>(getResult().getType());
    }
  }];
}

def Arbiter_DeallocOp : Arbiter_Op<"dealloc"> {
  let summary = "deallocation with an Arbiter placement policy";
  let description = [{
    `arbiter.dealloc` releases a memref previously produced by `arbiter.alloc`.
    Keeping the deallocation operation in the Arbiter dialect preserves the placement
    policy until lowering can emit the matching runtime deallocation call, such
    as `arbiter_dealloc`.
  }];

  let arguments = (ins Arg<AnyRankedOrUnrankedMemRef, "",
                           [MemFreeAt<0, FullEffect>]>:$memref,
                       OptionalAttr<StrAttr>:$target);

  let assemblyFormat = "$memref attr-dict `:` type($memref)";
}

#endif // ARBITER_DIALECT_ARBITER_IR_ARBITEROPS
