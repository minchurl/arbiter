#ifndef ARBITER_LLVM_HITM_SEED_OPTIONS_H
#define ARBITER_LLVM_HITM_SEED_OPTIONS_H

#include "llvm/Support/CommandLine.h"

#include <cstdint>
#include <string>

namespace arbiter::llvm::hitm_seed {

extern ::llvm::cl::opt<std::string> ReportPath;
extern ::llvm::cl::opt<unsigned> HITMMinScore;
extern ::llvm::cl::opt<unsigned> HITMSeedLimit;
extern ::llvm::cl::opt<std::string> HITMSeedSiteIds;
extern ::llvm::cl::opt<unsigned> HITMWeightEscapeReturn;
extern ::llvm::cl::opt<unsigned> HITMWeightEscapeStore;
extern ::llvm::cl::opt<unsigned> HITMWeightEscapeCall;
extern ::llvm::cl::opt<unsigned> HITMWeightSyncAtomic;
extern ::llvm::cl::opt<unsigned> HITMWeightSyncStore;
extern ::llvm::cl::opt<unsigned> HITMWeightSyncInlineAsm;
extern ::llvm::cl::opt<unsigned> HITMWeightSyncFile;
extern ::llvm::cl::opt<unsigned> HITMWeightWorkerEntry;
extern ::llvm::cl::opt<unsigned> HITMWeightWorkerReachable;
extern ::llvm::cl::opt<unsigned> HITMWeightSize;
extern ::llvm::cl::opt<bool> HITMRequireEscape;
extern ::llvm::cl::opt<bool> HITMRequireSync;
extern ::llvm::cl::opt<uint64_t> HITMLargeAllocationThreshold;
extern ::llvm::cl::opt<bool> HITMIncludeDynamicSize;
extern ::llvm::cl::opt<uint64_t> DynamicSizeEstimate;
extern ::llvm::cl::opt<uint64_t> MaxEstimatedBytes;

} // namespace arbiter::llvm::hitm_seed

#endif // ARBITER_LLVM_HITM_SEED_OPTIONS_H
