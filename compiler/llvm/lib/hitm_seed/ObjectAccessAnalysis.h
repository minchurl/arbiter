#ifndef ARBITER_OBJECT_ACCESS_ANALYSIS_H
#define ARBITER_OBJECT_ACCESS_ANALYSIS_H

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallVector.h"

namespace llvm {
class CallBase;
class Function;
class Module;
} // namespace llvm

namespace arbiter::llvm::hitm_seed {
struct ObjectAccessInfo {
  ::llvm::SmallPtrSet<const ::llvm::CallBase *, 32> rmwAllocations;
  ::llvm::SmallPtrSet<const ::llvm::Function *, 16> threadEntries;
  ::llvm::DenseMap<const ::llvm::Function *,
                   ::llvm::SmallVector<const ::llvm::Function *, 8>>
      calls;
};

// A bounded, flow-insensitive may-points-to analysis. Fields use byte offsets;
// dynamic array indices use congruences, preserving fields within an element.
// Calls have one call-site of context. Unknown external effects are not
// guessed.
ObjectAccessInfo analyzeObjectAccesses(::llvm::Module &module);
} // namespace arbiter::llvm::hitm_seed
#endif
