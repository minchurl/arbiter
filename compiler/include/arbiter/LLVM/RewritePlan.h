#ifndef ARBITER_LLVM_REWRITEPLAN_H
#define ARBITER_LLVM_REWRITEPLAN_H

#include "arbiter/LLVM/AllocationSite.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/IR/Module.h"

#include <cstdint>
#include <string>
#include <unordered_map>
#include <unordered_set>

namespace arbiter::llvm {

struct RewritePlan {
  void selectHeapAllocation(uint32_t siteId, std::string reason = "");
  void selectMMap(uint32_t siteId, std::string reason = "");

  bool shouldRewriteHeapAllocation(uint32_t siteId) const;
  bool shouldRewriteMMap(uint32_t siteId) const;

  std::unordered_set<uint32_t> heapAllocationSiteIds;
  std::unordered_set<uint32_t> mmapSiteIds;
  bool rewriteHeapDeallocationSites = false;
  bool rewriteMUnmapSites = false;
  std::unordered_map<uint32_t, std::string> selectionReasons;
};

RewritePlan buildAllRewritePlan(::llvm::ArrayRef<AllocationSite> sites);

bool applyHeapRewrites(::llvm::Module &module,
                       ::llvm::ArrayRef<AllocationSite> sites,
                       const RewritePlan &plan);
bool applyMMapRewrites(::llvm::Module &module,
                       ::llvm::ArrayRef<AllocationSite> sites,
                       const RewritePlan &plan);

} // namespace arbiter::llvm

#endif // ARBITER_LLVM_REWRITEPLAN_H
