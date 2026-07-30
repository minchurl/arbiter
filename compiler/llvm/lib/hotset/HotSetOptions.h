#ifndef ARBITER_LLVM_HOTSET_OPTIONS_H
#define ARBITER_LLVM_HOTSET_OPTIONS_H

#include "llvm/Support/CommandLine.h"

#include <cstdint>
#include <string>

namespace arbiter::llvm::hotset {

extern ::llvm::cl::opt<std::string> ReportPath;
extern ::llvm::cl::opt<unsigned> MinScore;
extern ::llvm::cl::opt<unsigned> SeedLimit;
extern ::llvm::cl::opt<std::string> SeedSiteIds;
extern ::llvm::cl::opt<std::string> Expansion;
extern ::llvm::cl::opt<unsigned> MaxSites;
extern ::llvm::cl::opt<bool> IncludeMMap;
extern ::llvm::cl::opt<std::string> Placement;
extern ::llvm::cl::opt<unsigned> TargetNode;
extern ::llvm::cl::opt<unsigned> WeightEscapeReturn;
extern ::llvm::cl::opt<unsigned> WeightEscapeStore;
extern ::llvm::cl::opt<unsigned> WeightEscapeCall;
extern ::llvm::cl::opt<unsigned> WeightSyncAtomic;
extern ::llvm::cl::opt<unsigned> WeightSyncStore;
extern ::llvm::cl::opt<unsigned> WeightSyncInlineAsm;
extern ::llvm::cl::opt<unsigned> WeightSyncFile;
extern ::llvm::cl::opt<unsigned> WeightWorkerEntry;
extern ::llvm::cl::opt<unsigned> WeightWorkerReachable;
extern ::llvm::cl::opt<unsigned> WeightSize;
extern ::llvm::cl::opt<bool> RequireEscape;
extern ::llvm::cl::opt<bool> RequireSync;
extern ::llvm::cl::opt<uint64_t> LargeAllocationThreshold;
extern ::llvm::cl::opt<bool> IncludeDynamicSize;
extern ::llvm::cl::opt<uint64_t> DynamicSizeEstimate;
extern ::llvm::cl::opt<uint64_t> MaxEstimatedBytes;
extern ::llvm::cl::opt<unsigned> MaxMembersPerSeed;
extern ::llvm::cl::opt<unsigned> MemberMinAffinity;
extern ::llvm::cl::opt<unsigned> MemberMaxCallDepth;
extern ::llvm::cl::opt<unsigned> MemberMaxLoadDepth;

} // namespace arbiter::llvm::hotset

#endif // ARBITER_LLVM_HOTSET_OPTIONS_H
