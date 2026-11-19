#ifndef ARBITER_COMPANION_ANALYSIS_H
#define ARBITER_COMPANION_ANALYSIS_H

#include "HITMRiskScoring.h"
#include <string>
#include <vector>

namespace arbiter::llvm::hitm_seed {
struct CompanionCandidate {
  uint32_t seed, companion;
  std::string function, access;
  unsigned loopDepth;
};

// Co-access candidates, not a proof of sharing, lock order, or profitability.
// Reporting never changes the existing seed selection or rewrite.
std::vector<CompanionCandidate>
discoverLoopCompanions(::llvm::Module &module,
                       const HITMSeedSelection &seeds);
} // namespace arbiter::llvm::hitm_seed
#endif
