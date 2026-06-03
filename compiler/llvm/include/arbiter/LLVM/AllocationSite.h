#ifndef ARBITER_LLVM_ALLOCATIONSITE_H
#define ARBITER_LLVM_ALLOCATIONSITE_H

#include "llvm/ADT/StringRef.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"

#include <cstdint>
#include <string>
#include <vector>

namespace arbiter::llvm {

enum class AllocationKind : uint8_t {
  Unknown,
  Malloc,
  Calloc,
  Free,
  CxxNew,
  CxxNewArray,
  CxxDelete,
  CxxDeleteArray,
  MMap,
  MUnmap,
};

struct AllocationSite {
  uint32_t id = 0;
  AllocationKind kind = AllocationKind::Unknown;
  ::llvm::CallBase *call = nullptr;
  std::string function;
  std::string file;
  uint32_t line = 0;
  std::string callee;
  std::string sizeExpr;
};

const char *kindToString(AllocationKind kind);
AllocationKind classifyCall(const ::llvm::CallBase &call);
bool isHeapAllocation(AllocationKind kind);
bool isHeapDeallocation(AllocationKind kind);
bool isMMapAllocation(AllocationKind kind);
bool isMMapDeallocation(AllocationKind kind);
bool isAnonymousMMap(const ::llvm::CallBase &call);

std::vector<AllocationSite> collectAllocationSites(::llvm::Module &module);

} // namespace arbiter::llvm

#endif // ARBITER_LLVM_ALLOCATIONSITE_H
