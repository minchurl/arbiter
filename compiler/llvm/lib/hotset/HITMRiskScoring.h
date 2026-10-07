#ifndef ARBITER_LLVM_HITM_RISK_SCORING_H
#define ARBITER_LLVM_HITM_RISK_SCORING_H

#include "arbiter/LLVM/AllocationSite.h"

#include "llvm/ADT/ArrayRef.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace llvm {
class Module;
}

namespace arbiter::llvm::hotset {

struct HITMRiskPolicy {
  uint32_t weightEscapeReturn = 3;
  uint32_t weightEscapeStore = 3;
  uint32_t weightEscapeCall = 2;
  uint32_t weightSyncAtomic = 3;
  uint32_t weightSyncStore = 2;
  uint32_t weightSyncInlineAsm = 2;
  uint32_t weightSyncFile = 1;
  uint32_t weightWorkerEntry = 3;
  uint32_t weightWorkerReachable = 2;
  uint32_t weightSize = 1;
  uint64_t largeAllocationThreshold = 4096;
  bool includeDynamicSize = true;
};

struct HITMRiskScore {
  uint64_t value = 0;
  bool hasEscape = false;
  bool hasSyncOrMutable = false;
  bool hasDynamicSize = false;
  uint64_t estimatedBytes = 0;
  std::string reasons;
};

struct HITMSeedPolicy {
  HITMRiskPolicy scoring;
  uint64_t minScore = 6;
  uint32_t seedLimit = 3;
  std::string explicitSiteIds;
  bool requireEscape = true;
  bool requireSync = true;
};

struct HITMSeedDecision {
  const AllocationSite *site = nullptr;
  HITMRiskScore score;
  bool selected = false;
  uint32_t groupId = 0;
};

struct HITMSeedSelection {
  std::vector<HITMSeedDecision> records;
};

class HITMRiskScorer {
public:
  HITMRiskScorer(::llvm::Module &module, HITMRiskPolicy policy);
  ~HITMRiskScorer();

  HITMRiskScorer(const HITMRiskScorer &) = delete;
  HITMRiskScorer &operator=(const HITMRiskScorer &) = delete;
  HITMRiskScorer(HITMRiskScorer &&) noexcept;
  HITMRiskScorer &operator=(HITMRiskScorer &&) noexcept;

  HITMRiskScore score(const AllocationSite &site) const;

private:
  struct Impl;
  std::unique_ptr<Impl> impl;
};

bool qualifiesAsHITMRiskSeed(const AllocationSite &site,
                             const HITMRiskScore &score, uint64_t minScore,
                             bool requireEscape, bool requireSync);

HITMSeedSelection selectHITMSeeds(
    ::llvm::Module &module, ::llvm::ArrayRef<AllocationSite> sites,
    const HITMSeedPolicy &policy);

} // namespace arbiter::llvm::hotset

#endif // ARBITER_LLVM_HITM_RISK_SCORING_H
