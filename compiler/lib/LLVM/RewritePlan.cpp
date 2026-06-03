#include "arbiter/LLVM/RewritePlan.h"

#include <utility>

using namespace llvm;

namespace arbiter::llvm {

void RewritePlan::selectHeapAllocation(uint32_t siteId, std::string reason) {
  heapAllocationSiteIds.insert(siteId);
  rewriteHeapDeallocationSites = true;
  if (!reason.empty())
    selectionReasons[siteId] = std::move(reason);
}

void RewritePlan::selectMMap(uint32_t siteId, std::string reason) {
  mmapSiteIds.insert(siteId);
  rewriteMUnmapSites = true;
  if (!reason.empty())
    selectionReasons[siteId] = std::move(reason);
}

bool RewritePlan::shouldRewriteHeapAllocation(uint32_t siteId) const {
  return heapAllocationSiteIds.count(siteId) != 0;
}

bool RewritePlan::shouldRewriteMMap(uint32_t siteId) const {
  return mmapSiteIds.count(siteId) != 0;
}

RewritePlan buildAllRewritePlan(ArrayRef<AllocationSite> sites) {
  RewritePlan plan;
  for (const AllocationSite &site : sites) {
    if (isHeapAllocation(site.kind)) {
      plan.selectHeapAllocation(site.id, "all-select");
      continue;
    }

    if (isMMapAllocation(site.kind) && site.call && isAnonymousMMap(*site.call))
      plan.selectMMap(site.id, "all-select");
  }
  return plan;
}

} // namespace arbiter::llvm
