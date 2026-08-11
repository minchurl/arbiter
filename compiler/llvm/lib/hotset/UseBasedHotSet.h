#ifndef ARBITER_LLVM_USE_BASED_HOT_SET_H
#define ARBITER_LLVM_USE_BASED_HOT_SET_H

#include "HITMRiskScoring.h"
#include "arbiter/LLVM/AllocationSite.h"

#include "llvm/ADT/ArrayRef.h"

#include <cstdint>
#include <string>
#include <vector>

namespace llvm {
class Module;
}

namespace arbiter::llvm::hotset {

enum class HotSetRole : uint8_t {
  Rejected,
  Seed,
  Member,
};

struct HotSetPolicy {
  std::string expansion = "use";
  uint32_t maxSites = 16;
  bool includeMMap = false;
  uint64_t dynamicSizeEstimate = 4096;
  uint64_t maxEstimatedBytes = 0;
  uint32_t maxMembersPerSeed = 4;
  uint32_t memberMinAffinity = 3;
  uint32_t memberMaxCallDepth = 1;
  uint32_t memberMaxLoadDepth = 2;
};

struct HotSetSiteDecision {
  const AllocationSite *site = nullptr;
  HITMRiskScore score;
  HotSetRole role = HotSetRole::Rejected;
  uint32_t groupId = 0;
  std::string reason;
  uint32_t memberAffinity = 0;
  std::string memberAccessKind;
  int32_t memberAccessDepth = -1;
};

struct HotSetSelection {
  std::vector<HotSetSiteDecision> records;
};

const char *hotSetRoleName(HotSetRole role);

HotSetSelection discoverUseBasedHotSet(
    ::llvm::Module &module, const HITMSeedSelection &hitmSeeds,
    const HotSetPolicy &policy);

} // namespace arbiter::llvm::hotset

#endif // ARBITER_LLVM_USE_BASED_HOT_SET_H
