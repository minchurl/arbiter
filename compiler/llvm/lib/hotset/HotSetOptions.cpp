#include "HotSetOptions.h"

using namespace llvm;

namespace arbiter::llvm::hotset {

cl::opt<std::string> ReportPath(
    "arbiter-hotset-report-path",
    cl::desc("Path for Arbiter LLVM hot-set reports; '-' means stdout"),
    cl::init("-"));

cl::opt<unsigned> MinScore(
    "arbiter-hotset-min-score",
    cl::desc("Minimum point score required for automatic hot-set seeds"),
    cl::init(6));

cl::opt<unsigned> SeedLimit(
    "arbiter-hotset-seed-limit",
    cl::desc("Maximum number of automatic hot-set seeds"), cl::init(3));

cl::opt<std::string> SeedSiteIds(
    "arbiter-hotset-seed-site-ids",
    cl::desc("Comma-separated explicit seed site IDs; overrides scored seeds"),
    cl::init(""));

cl::opt<std::string> Expansion(
    "arbiter-hotset-expansion",
    cl::desc("Hot-set expansion policy: none or use"), cl::init("use"));

cl::opt<unsigned> MaxSites(
    "arbiter-hotset-max-sites",
    cl::desc("Maximum number of selected hot-set sites including seeds"),
    cl::init(16));

cl::opt<bool> IncludeMMap(
    "arbiter-hotset-include-mmap",
    cl::desc("Allow anonymous mmap sites as expanded hot-set members"),
    cl::init(false));

cl::opt<std::string> Placement(
    "arbiter-hotset-placement",
    cl::desc("Hot-set placement policy encoded in rewritten call flags: local "
             "or target"),
    cl::init("local"));

cl::opt<unsigned> TargetNode(
    "arbiter-hotset-target-node",
    cl::desc("Target NUMA/CXL-like node encoded in rewritten call flags"),
    cl::init(0));

cl::opt<unsigned> WeightEscapeReturn(
    "arbiter-hotset-weight-escape-return",
    cl::desc("Point weight for an allocation escaping through return"),
    cl::init(3));

cl::opt<unsigned> WeightEscapeStore(
    "arbiter-hotset-weight-escape-store",
    cl::desc("Point weight for storing an allocation-derived pointer"),
    cl::init(3));

cl::opt<unsigned> WeightEscapeCall(
    "arbiter-hotset-weight-escape-call",
    cl::desc("Point weight for passing an allocation to a non-ignored call"),
    cl::init(2));

cl::opt<unsigned> WeightSyncAtomic(
    "arbiter-hotset-weight-sync-atomic",
    cl::desc("Point weight for same-function atomic RMW or cmpxchg"),
    cl::init(3));

cl::opt<unsigned> WeightSyncStore(
    "arbiter-hotset-weight-sync-store",
    cl::desc("Point weight for same-function atomic or volatile stores"),
    cl::init(2));

cl::opt<unsigned> WeightSyncInlineAsm(
    "arbiter-hotset-weight-sync-inline-asm",
    cl::desc("Point weight for same-function lock/cmpxchg inline assembly"),
    cl::init(2));

cl::opt<unsigned> WeightSyncFile(
    "arbiter-hotset-weight-sync-file",
    cl::desc("Point weight for synchronization mutation in the same debug file"),
    cl::init(1));

cl::opt<unsigned> WeightWorkerEntry(
    "arbiter-hotset-weight-worker-entry",
    cl::desc("Point weight for allocations in a pthread worker entry"),
    cl::init(3));

cl::opt<unsigned> WeightWorkerReachable(
    "arbiter-hotset-weight-worker-reachable",
    cl::desc("Point weight for allocations reachable from a pthread worker"),
    cl::init(2));

cl::opt<unsigned> WeightSize(
    "arbiter-hotset-weight-size",
    cl::desc("Point weight for configured large or dynamic allocation sizes"),
    cl::init(1));

cl::opt<bool> RequireEscape(
    "arbiter-hotset-require-escape",
    cl::desc("Require an escape signal for automatic seed selection"),
    cl::init(true));

cl::opt<bool> RequireSync(
    "arbiter-hotset-require-sync",
    cl::desc("Require a sync/mutable signal for automatic seed selection"),
    cl::init(true));

cl::opt<uint64_t> LargeAllocationThreshold(
    "arbiter-hotset-large-allocation-threshold",
    cl::desc("Bytes required for the large-allocation score; zero disables it"),
    cl::init(4096));

cl::opt<bool> IncludeDynamicSize(
    "arbiter-hotset-include-dynamic-size",
    cl::desc("Award the size score to dynamically sized allocations"),
    cl::init(true));

cl::opt<uint64_t> DynamicSizeEstimate(
    "arbiter-hotset-dynamic-size-estimate",
    cl::desc("Estimated bytes charged to a dynamically sized selected site"),
    cl::init(4096));

cl::opt<uint64_t> MaxEstimatedBytes(
    "arbiter-hotset-max-estimated-bytes",
    cl::desc("Maximum estimated bytes across the hot set; zero is unlimited"),
    cl::init(0));

cl::opt<unsigned> MaxMembersPerSeed(
    "arbiter-hotset-max-members-per-seed",
    cl::desc("Maximum access-affinity members assigned to one seed; zero is "
             "unlimited"),
    cl::init(4));

cl::opt<unsigned> MemberMinAffinity(
    "arbiter-hotset-member-min-affinity",
    cl::desc("Minimum member affinity: 1 ownership, 3 read, or 5 write"),
    cl::init(3));

cl::opt<unsigned> MemberMaxCallDepth(
    "arbiter-hotset-member-max-call-depth",
    cl::desc("Maximum direct-call depth for member access tracing"),
    cl::init(1));

cl::opt<unsigned> MemberMaxLoadDepth(
    "arbiter-hotset-member-max-load-depth",
    cl::desc("Maximum pointer-load depth for member access tracing"),
    cl::init(2));

} // namespace arbiter::llvm::hotset
