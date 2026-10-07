#ifndef ARBITER_LLVM_HOTSET_OPTIONS_H
#define ARBITER_LLVM_HOTSET_OPTIONS_H

#include "llvm/Support/CommandLine.h"

#include <cstdint>
#include <string>

namespace arbiter::llvm::hotset {

extern ::llvm::cl::opt<std::string> ReportPath;
extern ::llvm::cl::opt<unsigned> HITMMinScore;
extern ::llvm::cl::opt<unsigned> HITMSeedLimit;
extern ::llvm::cl::opt<std::string> HITMSeedSiteIds;
extern ::llvm::cl::opt<std::string> Expansion;
extern ::llvm::cl::opt<unsigned> MaxSites;
extern ::llvm::cl::opt<bool> IncludeMMap;
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
extern ::llvm::cl::opt<unsigned> MaxMembersPerSeed;
extern ::llvm::cl::opt<unsigned> MemberMinAffinity;
extern ::llvm::cl::opt<unsigned> MemberMaxCallDepth;
extern ::llvm::cl::opt<unsigned> MemberMaxLoadDepth;

} // namespace arbiter::llvm::hotset

#endif // ARBITER_LLVM_HOTSET_OPTIONS_H
