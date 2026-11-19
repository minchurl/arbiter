#ifndef ARBITER_OBJECT_ACCESS_ANALYSIS_H
#define ARBITER_OBJECT_ACCESS_ANALYSIS_H

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"

namespace llvm {
class CallBase;
class Function;
class Instruction;
class Module;
} // namespace llvm

namespace arbiter::llvm::hitm_seed {
struct ObjectAccessInfo {
  ::llvm::SmallPtrSet<const ::llvm::CallBase *, 32> rmwAllocations;
  ::llvm::SmallPtrSet<const ::llvm::Function *, 16> threadEntries;
  ::llvm::DenseMap<const ::llvm::Function *,
                   ::llvm::SmallVector<const ::llvm::Function *, 8>>
      calls;
  // Optional provenance for companion discovery; ordinary seed scoring does
  // not request or consume this evidence. nullptr marks an unresolved context.
  ::llvm::DenseMap<const ::llvm::Instruction *,
                   ::llvm::SmallVector<const ::llvm::CallBase *, 4>> accesses;
};

// A bounded, flow-insensitive may-points-to analysis. Fields use byte offsets;
// dynamic array indices use congruences, preserving fields within an element.
// Calls have one call-site of context. Unknown external effects are not
// guessed.
ObjectAccessInfo analyzeObjectAccesses(::llvm::Module &module,
                                      bool collectAccesses = false);
} // namespace arbiter::llvm::hitm_seed
#endif
