#include "CompanionAnalysis.h"
#include "ObjectAccessAnalysis.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"

#include <algorithm>
#include <map>
#include <set>
#include <tuple>

using namespace llvm;
namespace arbiter::llvm::hitm_seed {
std::vector<CompanionCandidate>
discoverLoopCompanions(Module &module, const HITMSeedSelection &selection) {
  auto evidence = analyzeObjectAccesses(module, true);
  DenseMap<const CallBase *, uint32_t> ids;
  std::set<uint32_t> seeds;
  for (const auto &record : selection.records) {
    if (record.site->call && isHeapAllocation(record.site->kind))
      ids[record.site->call] = record.site->id;
    if (record.selected)
      seeds.insert(record.site->id);
  }
  SmallPtrSet<const Function *, 32> workers;
  SmallVector<const Function *, 32> pending(evidence.threadEntries.begin(),
                                           evidence.threadEntries.end());
  while (!pending.empty()) {
    const Function *function = pending.pop_back_val();
    if (!workers.insert(function).second)
      continue;
    auto found = evidence.calls.find(function);
    if (found != evidence.calls.end())
      pending.append(found->second);
  }
  // Keep the deepest common loop as the most specific evidence per pair and
  // function. Nested retry loops must not hide the surrounding operation loop.
  std::map<std::tuple<uint32_t, uint32_t, std::string>, CompanionCandidate> found;
  for (Function &function : module) {
    if (function.isDeclaration() || !workers.contains(&function))
      continue;
    DominatorTree dominators(function);
    LoopInfo loops(dominators);
    std::map<const Loop *, std::map<uint32_t, unsigned>> accesses;
    for (const Instruction &instruction : instructions(function)) {
      auto origins = evidence.accesses.find(&instruction);
      if (origins == evidence.accesses.end() || origins->second.size() != 1)
        continue;
      auto id = ids.find(origins->second.front());
      if (id == ids.end())
        continue;
      unsigned kind = isa<LoadInst>(instruction) ? 1
                      : isa<StoreInst>(instruction) ? 2 : 3;
      for (const Loop *loop = loops.getLoopFor(instruction.getParent()); loop;
           loop = loop->getParentLoop())
        accesses[loop][id->second] |= kind;
    }
    for (const auto &[loop, sites] : accesses)
      for (const auto &[seed, ignored] : sites) {
        (void)ignored;
        if (!seeds.count(seed))
          continue;
        for (const auto &[candidate, kind] : sites) {
          if (seeds.count(candidate))
            continue;
          auto key = std::make_tuple(seed, candidate, function.getName().str());
          auto &entry = found[key];
          const char *access = kind == 1 ? "read" : kind == 2 ? "write" : "read-write";
          if (entry.loopDepth < loop->getLoopDepth())
            entry = {seed, candidate, function.getName().str(), access,
                     loop->getLoopDepth(), loop->getHeader()};
          else if (entry.loopDepth == loop->getLoopDepth()) {
            if (entry.access != access)
              entry.access = "read-write";
            if (entry.loopHeader != loop->getHeader())
              entry.loopHeader = nullptr;
          }
        }
      }
  }
  std::vector<CompanionCandidate> result;
  for (auto &[key, value] : found) {
    (void)key;
    result.push_back(std::move(value));
  }
  return result;
}
} // namespace arbiter::llvm::hitm_seed
