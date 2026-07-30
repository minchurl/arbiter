#include "UseBasedHotSet.h"

#include "HotSetOptions.h"

#include "llvm/ADT/APInt.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/Hashing.h"
#include "llvm/ADT/MapVector.h"
#include "llvm/ADT/SmallPtrSet.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/Twine.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Operator.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

using namespace llvm;

namespace arbiter::llvm::hotset {
namespace {

enum class MemberAccessKind : uint8_t {
  None = 0,
  Attach = 1,
  Pointer = 2,
  Read = 3,
  Write = 5,
};

struct Seed {
  size_t recordIndex = 0;
  uint32_t groupId = 0;
};

struct MemberCandidate {
  size_t recordIndex = 0;
  uint32_t groupId = 0;
  MemberAccessKind accessKind = MemberAccessKind::None;
  unsigned accessDepth = 0;
};

[[noreturn]] void failConfig(const Twine &message) {
  report_fatal_error(Twine("arbiter hotset config: ") + message, false);
}

void appendReason(HotSetSiteDecision &record, StringRef reason) {
  if (reason.empty())
    return;
  if (!record.reason.empty())
    record.reason += ';';
  record.reason += reason.str();
}

std::vector<uint32_t> parseExplicitSeedIds(StringRef text) {
  SmallVector<StringRef, 16> parts;
  text.split(parts, ',', -1, false);

  std::vector<uint32_t> ids;
  std::unordered_set<uint32_t> seen;
  for (StringRef part : parts) {
    part = part.trim();
    if (part.empty())
      continue;

    uint32_t id = 0;
    if (part.getAsInteger(10, id))
      failConfig(Twine("invalid seed site id '") + part + "'");
    if (seen.insert(id).second)
      ids.push_back(id);
  }

  std::sort(ids.begin(), ids.end());
  return ids;
}

void validateDiscoveryOptions() {
  StringRef expansion = Expansion.getValue();
  if (expansion != "none" && expansion != "use") {
    failConfig(Twine("invalid expansion '") + expansion +
               "'; expected none or use");
  }

  unsigned affinity = MemberMinAffinity;
  if (affinity != 1 && affinity != 3 && affinity != 5) {
    failConfig(Twine("invalid member-min-affinity ") + Twine(affinity) +
               "; expected 1, 3, or 5");
  }
  if (MemberMaxCallDepth > 4)
    failConfig("member-max-call-depth must be between 0 and 4");
  if (MemberMaxLoadDepth > 4)
    failConfig("member-max-load-depth must be between 0 and 4");
}

HITMRiskPolicy scoringPolicyFromOptions() {
  HITMRiskPolicy policy;
  policy.weightEscapeReturn = WeightEscapeReturn;
  policy.weightEscapeStore = WeightEscapeStore;
  policy.weightEscapeCall = WeightEscapeCall;
  policy.weightSyncAtomic = WeightSyncAtomic;
  policy.weightSyncStore = WeightSyncStore;
  policy.weightSyncInlineAsm = WeightSyncInlineAsm;
  policy.weightSyncFile = WeightSyncFile;
  policy.weightWorkerEntry = WeightWorkerEntry;
  policy.weightWorkerReachable = WeightWorkerReachable;
  policy.weightSize = WeightSize;
  policy.largeAllocationThreshold = LargeAllocationThreshold;
  policy.includeDynamicSize = IncludeDynamicSize;
  policy.dynamicSizeEstimate = DynamicSizeEstimate;
  return policy;
}

bool exceedsByteBudget(uint64_t selectedBytes, uint64_t nextBytes) {
  uint64_t limit = MaxEstimatedBytes;
  if (limit == 0)
    return false;
  return nextBytes > limit || selectedBytes > limit - nextBytes;
}

void addEstimatedBytes(uint64_t &selectedBytes, uint64_t nextBytes) {
  if (selectedBytes >
      std::numeric_limits<uint64_t>::max() - nextBytes) {
    selectedBytes = std::numeric_limits<uint64_t>::max();
    return;
  }
  selectedBytes += nextBytes;
}

bool isSupportedMember(const AllocationSite &site) {
  return isHeapAllocation(site.kind) || isMMapAllocation(site.kind);
}

unsigned affinityForAccess(MemberAccessKind kind) {
  return static_cast<unsigned>(kind);
}

const char *accessKindName(MemberAccessKind kind) {
  switch (kind) {
  case MemberAccessKind::Attach:
    return "attach";
  case MemberAccessKind::Pointer:
    return "pointer";
  case MemberAccessKind::Read:
    return "read";
  case MemberAccessKind::Write:
    return "write";
  case MemberAccessKind::None:
    return "";
  }
  return "";
}

bool seedOrder(const HotSetSiteDecision *left,
               const HotSetSiteDecision *right) {
  if (left->score.value != right->score.value)
    return left->score.value > right->score.value;
  return left->site->id < right->site->id;
}

std::vector<Seed>
chooseSeeds(std::vector<HotSetSiteDecision> &records,
            const std::unordered_map<uint32_t, size_t> &recordBySiteId,
            ArrayRef<uint32_t> explicitSeedIds,
            std::unordered_set<uint32_t> &automaticCandidates,
            std::unordered_set<uint32_t> &seedBudgetRejected,
            uint64_t &selectedEstimatedBytes) {
  std::vector<HotSetSiteDecision *> candidates;

  if (!explicitSeedIds.empty()) {
    if (explicitSeedIds.size() > MaxSites) {
      failConfig(Twine("explicit seed count ") +
                 Twine(explicitSeedIds.size()) +
                 " exceeds max-sites " + Twine(MaxSites));
    }

    for (uint32_t id : explicitSeedIds) {
      auto recordIt = recordBySiteId.find(id);
      if (recordIt == recordBySiteId.end())
        failConfig(Twine("explicit seed site ") + Twine(id) +
                   " does not exist");

      HotSetSiteDecision &record = records[recordIt->second];
      if (!isHeapAllocation(record.site->kind)) {
        failConfig(Twine("explicit seed site ") + Twine(id) +
                   " is not a heap allocation");
      }
      candidates.push_back(&record);
    }
  } else {
    for (HotSetSiteDecision &record : records) {
      if (!qualifiesAsHITMRiskSeed(*record.site, record.score, MinScore,
                                   RequireEscape, RequireSync))
        continue;
      automaticCandidates.insert(record.site->id);
      candidates.push_back(&record);
    }
  }

  std::sort(candidates.begin(), candidates.end(), seedOrder);

  std::vector<Seed> seeds;
  seeds.reserve(candidates.size());
  uint32_t groupId = 1;
  for (HotSetSiteDecision *record : candidates) {
    if (explicitSeedIds.empty() &&
        (seeds.size() >= SeedLimit || seeds.size() >= MaxSites))
      break;

    if (exceedsByteBudget(selectedEstimatedBytes,
                          record->score.estimatedBytes)) {
      if (!explicitSeedIds.empty()) {
        failConfig(Twine("explicit seeds exceed max-estimated-bytes ") +
                   Twine(MaxEstimatedBytes.getValue()));
      }
      seedBudgetRejected.insert(record->site->id);
      continue;
    }

    record->role = HotSetRole::Seed;
    record->groupId = groupId;
    appendReason(*record, explicitSeedIds.empty()
                              ? "hotset-seed:score-top-k"
                              : "hotset-seed:explicit");
    seeds.push_back(
        {static_cast<size_t>(record - records.data()), groupId++});
    addEstimatedBytes(selectedEstimatedBytes,
                      record->score.estimatedBytes);
  }
  return seeds;
}

struct OffsetLevel {
  explicit OffsetLevel(unsigned bitWidth)
      : constantOffset(bitWidth, 0, true) {}

  APInt constantOffset;
  SmallVector<APInt, 4> dynamicStrides;
};

struct AccessPath {
  explicit AccessPath(unsigned bitWidth) : bitWidth(bitWidth) {
    levels.emplace_back(bitWidth);
  }

  unsigned bitWidth;
  std::vector<OffsetLevel> levels;
};

struct TraceState {
  const Value *value = nullptr;
  AccessPath path;
  unsigned callDepth = 0;
};

struct TraceStateKey {
  const Value *value = nullptr;
  std::string path;
  unsigned callDepth = 0;

  bool operator==(const TraceStateKey &other) const {
    return value == other.value && path == other.path &&
           callDepth == other.callDepth;
  }
};

struct TraceStateKeyHash {
  size_t operator()(const TraceStateKey &key) const {
    return static_cast<size_t>(
        hash_combine(key.value, key.path, key.callDepth));
  }
};

struct PathObservation {
  MemberAccessKind accessKind = MemberAccessKind::None;
  unsigned accessDepth = std::numeric_limits<unsigned>::max();
};

struct Attachment {
  size_t recordIndex = 0;
  std::string path;
  unsigned accessDepth = 0;
};

void writeSignedAPInt(raw_ostream &stream, const APInt &value) {
  SmallString<32> text;
  value.toString(text, 10, true);
  stream << text;
}

std::string accessPathKey(const AccessPath &path, size_t levelCount) {
  std::string result;
  raw_string_ostream stream(result);
  stream << path.bitWidth << ':';
  for (size_t levelIndex = 0; levelIndex < levelCount; ++levelIndex) {
    const OffsetLevel &level = path.levels[levelIndex];
    stream << '[';
    writeSignedAPInt(stream, level.constantOffset);
    stream << ';';
    for (const APInt &stride : level.dynamicStrides) {
      writeSignedAPInt(stream, stride);
      stream << ',';
    }
    stream << ']';
  }
  return stream.str();
}

std::string accessPathKey(const AccessPath &path) {
  return accessPathKey(path, path.levels.size());
}

bool appendGEPOffset(const GEPOperator &gep, const DataLayout &dataLayout,
                     AccessPath &path) {
  unsigned bitWidth =
      dataLayout.getIndexTypeSizeInBits(gep.getPointerOperandType());
  if (bitWidth != path.bitWidth)
    return false;

  MapVector<Value *, APInt> variableOffsets;
  APInt constantOffset(bitWidth, 0, true);
  if (!gep.collectOffset(dataLayout, bitWidth, variableOffsets,
                         constantOffset)) {
    return false;
  }

  OffsetLevel &level = path.levels.back();
  level.constantOffset += constantOffset;
  for (const auto &[value, stride] : variableOffsets) {
    (void)value;
    level.dynamicStrides.push_back(stride);
  }
  std::sort(level.dynamicStrides.begin(), level.dynamicStrides.end(),
            [](const APInt &left, const APInt &right) {
              return left.slt(right);
            });
  return true;
}

void recordObservation(
    std::unordered_map<std::string, PathObservation> &observations,
    StringRef path, MemberAccessKind accessKind, unsigned accessDepth) {
  PathObservation &observation = observations[path.str()];
  unsigned affinity = affinityForAccess(accessKind);
  unsigned oldAffinity = affinityForAccess(observation.accessKind);
  if (affinity > oldAffinity ||
      (affinity == oldAffinity &&
       accessDepth < observation.accessDepth)) {
    observation.accessKind = accessKind;
    observation.accessDepth = accessDepth;
  }
}

void recordMemberPrefixObservations(
    const AccessPath &path,
    std::unordered_map<std::string, PathObservation> &observations,
    MemberAccessKind accessKind, unsigned accessDepth) {
  for (size_t levelCount = 1; levelCount < path.levels.size();
       ++levelCount) {
    recordObservation(observations, accessPathKey(path, levelCount),
                      accessKind, accessDepth);
  }
}

void collectAllocationOrigins(
    const Value *value,
    const std::unordered_map<const Value *, size_t> &allocationByValue,
    SmallPtrSetImpl<const Value *> &visited,
    SmallVectorImpl<size_t> &origins) {
  if (!value || !value->getType()->isPointerTy() ||
      !visited.insert(value).second) {
    return;
  }

  auto allocationIt = allocationByValue.find(value);
  if (allocationIt != allocationByValue.end()) {
    origins.push_back(allocationIt->second);
    return;
  }

  if (const auto *phi = dyn_cast<PHINode>(value)) {
    for (const Value *incoming : phi->incoming_values())
      collectAllocationOrigins(incoming, allocationByValue, visited, origins);
    return;
  }
  if (const auto *select = dyn_cast<SelectInst>(value)) {
    collectAllocationOrigins(select->getTrueValue(), allocationByValue,
                             visited, origins);
    collectAllocationOrigins(select->getFalseValue(), allocationByValue,
                             visited, origins);
    return;
  }
  if (const auto *freeze = dyn_cast<FreezeInst>(value)) {
    collectAllocationOrigins(freeze->getOperand(0), allocationByValue,
                             visited, origins);
    return;
  }

  const auto *operation = dyn_cast<Operator>(value);
  if (!operation)
    return;
  switch (operation->getOpcode()) {
  case Instruction::AddrSpaceCast:
  case Instruction::BitCast:
  case Instruction::GetElementPtr:
    collectAllocationOrigins(operation->getOperand(0), allocationByValue,
                             visited, origins);
    return;
  default:
    return;
  }
}

SmallVector<size_t, 4> allocationOrigins(
    const Value *value,
    const std::unordered_map<const Value *, size_t> &allocationByValue) {
  SmallPtrSet<const Value *, 16> visited;
  SmallVector<size_t, 4> origins;
  collectAllocationOrigins(value, allocationByValue, visited, origins);
  std::sort(origins.begin(), origins.end());
  origins.erase(std::unique(origins.begin(), origins.end()), origins.end());
  return origins;
}

const Function *getDirectDefinedCallee(const CallBase &call) {
  const Value *called = call.getCalledOperand()->stripPointerCasts();
  const auto *callee = dyn_cast<Function>(called);
  if (!callee || callee->isDeclaration())
    return nullptr;
  return callee;
}

bool isIgnoredMemberAccessCall(const CallBase &call) {
  AllocationKind kind = classifyCall(call);
  if (isHeapDeallocation(kind) || isMMapDeallocation(kind))
    return true;

  if (const Function *callee = call.getCalledFunction())
    return callee->isIntrinsic();
  return false;
}

MemberAccessKind classifyBoundaryCallArgument(const CallBase &call,
                                              unsigned argumentIndex) {
  if (const auto *transfer = dyn_cast<MemTransferInst>(&call)) {
    if (call.getArgOperand(argumentIndex) == transfer->getRawDest())
      return MemberAccessKind::Write;
    if (call.getArgOperand(argumentIndex) == transfer->getRawSource())
      return MemberAccessKind::Read;
  }
  if (const auto *set = dyn_cast<MemSetInst>(&call)) {
    if (call.getArgOperand(argumentIndex) == set->getRawDest())
      return MemberAccessKind::Write;
  }
  if (isIgnoredMemberAccessCall(call))
    return MemberAccessKind::None;

  if (call.paramHasAttr(argumentIndex, Attribute::ReadNone))
    return MemberAccessKind::Pointer;
  if (call.paramHasAttr(argumentIndex, Attribute::WriteOnly))
    return MemberAccessKind::Write;
  if (call.paramHasAttr(argumentIndex, Attribute::ReadOnly))
    return MemberAccessKind::Read;

  if (call.doesNotAccessMemory())
    return MemberAccessKind::Pointer;
  if (call.onlyWritesMemory())
    return MemberAccessKind::Write;
  if (call.onlyReadsMemory())
    return MemberAccessKind::Read;
  return MemberAccessKind::Pointer;
}

bool isBetterMemberCandidate(const MemberCandidate &candidate,
                             const MemberCandidate &current) {
  unsigned affinity = affinityForAccess(candidate.accessKind);
  unsigned currentAffinity = affinityForAccess(current.accessKind);
  if (affinity != currentAffinity)
    return affinity > currentAffinity;
  if (candidate.accessDepth != current.accessDepth)
    return candidate.accessDepth < current.accessDepth;
  return candidate.groupId < current.groupId;
}

std::vector<MemberCandidate> discoverSeedMemberCandidates(
    Module &module, const Seed &seed,
    ArrayRef<HotSetSiteDecision> records,
    const std::unordered_map<const Value *, size_t> &allocationByValue) {
  const HotSetSiteDecision &seedRecord = records[seed.recordIndex];
  if (!seedRecord.site->call)
    return {};

  const DataLayout &dataLayout = module.getDataLayout();
  unsigned bitWidth =
      dataLayout.getIndexTypeSizeInBits(seedRecord.site->call->getType());
  if (bitWidth == 0)
    return {};

  SmallVector<TraceState, 64> worklist;
  std::unordered_set<TraceStateKey, TraceStateKeyHash> visited;
  std::vector<Attachment> attachments;
  std::unordered_map<std::string, PathObservation> observations;

  auto enqueue = [&](const Value *value, AccessPath path,
                     unsigned callDepth) {
    if (!value || !value->getType()->isPointerTy())
      return;
    std::string pathText = accessPathKey(path);
    TraceStateKey key{value, pathText, callDepth};
    if (!visited.insert(std::move(key)).second)
      return;
    worklist.push_back({value, std::move(path), callDepth});
  };

  enqueue(seedRecord.site->call, AccessPath(bitWidth), 0);

  while (!worklist.empty()) {
    TraceState state = std::move(worklist.back());
    worklist.pop_back();
    unsigned loadDepth =
        static_cast<unsigned>(state.path.levels.size() - 1);

    for (const User *user : state.value->users()) {
      if (const auto *gep = dyn_cast<GEPOperator>(user)) {
        if (gep->getPointerOperand() != state.value)
          continue;
        AccessPath nextPath = state.path;
        if (appendGEPOffset(*gep, dataLayout, nextPath))
          enqueue(user, std::move(nextPath), state.callDepth);
        continue;
      }

      if (isa<PHINode>(user) || isa<SelectInst>(user) ||
          isa<FreezeInst>(user)) {
        if (user->getType()->isPointerTy())
          enqueue(user, state.path, state.callDepth);
        continue;
      }

      if (const auto *operation = dyn_cast<Operator>(user)) {
        if (operation->getType()->isPointerTy() &&
            (operation->getOpcode() == Instruction::AddrSpaceCast ||
             operation->getOpcode() == Instruction::BitCast)) {
          enqueue(user, state.path, state.callDepth);
          continue;
        }
      }

      if (const auto *load = dyn_cast<LoadInst>(user)) {
        if (load->getPointerOperand() != state.value)
          continue;

        if (load->getType()->isPointerTy()) {
          unsigned nextLoadDepth = loadDepth + 1;
          if (nextLoadDepth > MemberMaxLoadDepth)
            continue;
          unsigned accessDepth = state.callDepth + nextLoadDepth;
          recordObservation(observations, accessPathKey(state.path),
                            MemberAccessKind::Pointer, accessDepth);
          recordMemberPrefixObservations(
              state.path, observations, MemberAccessKind::Read, accessDepth);

          AccessPath nextPath = state.path;
          nextPath.levels.emplace_back(bitWidth);
          enqueue(load, std::move(nextPath), state.callDepth);
        } else {
          recordMemberPrefixObservations(
              state.path, observations, MemberAccessKind::Read,
              state.callDepth + loadDepth);
        }
        continue;
      }

      if (const auto *store = dyn_cast<StoreInst>(user)) {
        if (store->getPointerOperand() != state.value)
          continue;

        unsigned accessDepth = state.callDepth + loadDepth;
        recordMemberPrefixObservations(
            state.path, observations, MemberAccessKind::Write, accessDepth);
        for (size_t recordIndex :
             allocationOrigins(store->getValueOperand(), allocationByValue)) {
          if (records[recordIndex].role == HotSetRole::Seed)
            continue;
          attachments.push_back(
              {recordIndex, accessPathKey(state.path), accessDepth});
        }
        continue;
      }

      if (const auto *atomicRmw = dyn_cast<AtomicRMWInst>(user)) {
        if (atomicRmw->getPointerOperand() == state.value) {
          recordMemberPrefixObservations(
              state.path, observations, MemberAccessKind::Write,
              state.callDepth + loadDepth);
        }
        continue;
      }
      if (const auto *cmpXchg = dyn_cast<AtomicCmpXchgInst>(user)) {
        if (cmpXchg->getPointerOperand() == state.value) {
          recordMemberPrefixObservations(
              state.path, observations, MemberAccessKind::Write,
              state.callDepth + loadDepth);
        }
        continue;
      }

      const auto *call = dyn_cast<CallBase>(user);
      if (!call)
        continue;

      for (unsigned argumentIndex = 0;
           argumentIndex < call->arg_size(); ++argumentIndex) {
        if (call->getArgOperand(argumentIndex) != state.value)
          continue;

        if (const Function *callee = getDirectDefinedCallee(*call);
            callee && state.callDepth < MemberMaxCallDepth &&
            argumentIndex < callee->arg_size()) {
          enqueue(callee->getArg(argumentIndex), state.path,
                  state.callDepth + 1);
          continue;
        }

        MemberAccessKind accessKind =
            classifyBoundaryCallArgument(*call, argumentIndex);
        if (accessKind != MemberAccessKind::None) {
          recordMemberPrefixObservations(
              state.path, observations, accessKind,
              state.callDepth + loadDepth);
        }
      }
    }
  }

  std::unordered_map<size_t, MemberCandidate> bestByRecord;
  for (const Attachment &attachment : attachments) {
    MemberCandidate candidate;
    candidate.recordIndex = attachment.recordIndex;
    candidate.groupId = seed.groupId;
    candidate.accessKind = MemberAccessKind::Attach;
    candidate.accessDepth = attachment.accessDepth;

    auto observationIt = observations.find(attachment.path);
    if (observationIt != observations.end() &&
        affinityForAccess(observationIt->second.accessKind) >
            affinityForAccess(candidate.accessKind)) {
      candidate.accessKind = observationIt->second.accessKind;
      candidate.accessDepth = observationIt->second.accessDepth;
    }

    auto [candidateIt, inserted] =
        bestByRecord.emplace(candidate.recordIndex, candidate);
    if (!inserted &&
        isBetterMemberCandidate(candidate, candidateIt->second)) {
      candidateIt->second = candidate;
    }
  }

  std::vector<MemberCandidate> candidates;
  candidates.reserve(bestByRecord.size());
  for (const auto &[recordIndex, candidate] : bestByRecord) {
    (void)recordIndex;
    candidates.push_back(candidate);
  }
  return candidates;
}

std::vector<MemberCandidate>
discoverMemberCandidates(Module &module, ArrayRef<Seed> seeds,
                         ArrayRef<HotSetSiteDecision> records) {
  std::unordered_map<const Value *, size_t> allocationByValue;
  for (size_t recordIndex = 0; recordIndex < records.size(); ++recordIndex) {
    const HotSetSiteDecision &record = records[recordIndex];
    if (isSupportedMember(*record.site) && record.site->call)
      allocationByValue.emplace(record.site->call, recordIndex);
  }

  std::unordered_map<size_t, MemberCandidate> bestByRecord;
  for (const Seed &seed : seeds) {
    for (const MemberCandidate &candidate :
         discoverSeedMemberCandidates(module, seed, records,
                                      allocationByValue)) {
      auto [candidateIt, inserted] =
          bestByRecord.emplace(candidate.recordIndex, candidate);
      if (!inserted &&
          isBetterMemberCandidate(candidate, candidateIt->second)) {
        candidateIt->second = candidate;
      }
    }
  }

  std::vector<MemberCandidate> candidates;
  candidates.reserve(bestByRecord.size());
  for (const auto &[recordIndex, candidate] : bestByRecord) {
    (void)recordIndex;
    candidates.push_back(candidate);
  }
  std::sort(candidates.begin(), candidates.end(),
            [&](const MemberCandidate &left,
                const MemberCandidate &right) {
              if (left.groupId != right.groupId)
                return left.groupId < right.groupId;
              unsigned leftAffinity =
                  affinityForAccess(left.accessKind);
              unsigned rightAffinity =
                  affinityForAccess(right.accessKind);
              if (leftAffinity != rightAffinity)
                return leftAffinity > rightAffinity;
              if (left.accessDepth != right.accessDepth)
                return left.accessDepth < right.accessDepth;
              return records[left.recordIndex].site->id <
                     records[right.recordIndex].site->id;
            });
  return candidates;
}

StringRef memberRejectionReason(const HotSetSiteDecision &record) {
  if (isHeapAllocation(record.site->kind))
    return StringRef();

  if (isMMapAllocation(record.site->kind)) {
    if (!IncludeMMap)
      return "hotset-rejected:mmap-disabled";
    if (!record.site->call || !isAnonymousMMap(*record.site->call))
      return "hotset-rejected:mmap-not-anonymous";
    return StringRef();
  }

  return "hotset-rejected:unsupported-kind";
}

HotSetSelection buildSelection(Module &module,
                               ArrayRef<AllocationSite> sites) {
  validateDiscoveryOptions();

  HotSetSelection selection;
  selection.records.reserve(sites.size());
  HITMRiskScorer scorer(module, scoringPolicyFromOptions());

  std::unordered_map<uint32_t, size_t> recordBySiteId;
  recordBySiteId.reserve(sites.size());
  for (const AllocationSite &site : sites) {
    HotSetSiteDecision record;
    record.site = &site;
    record.score = scorer.score(site);
    record.reason = record.score.reasons;
    recordBySiteId.emplace(site.id, selection.records.size());
    selection.records.push_back(std::move(record));
  }

  std::vector<uint32_t> explicitSeedIds =
      parseExplicitSeedIds(SeedSiteIds.getValue());
  std::unordered_set<uint32_t> automaticCandidates;
  std::unordered_set<uint32_t> seedBudgetRejected;
  uint64_t selectedEstimatedBytes = 0;
  std::vector<Seed> seeds =
      chooseSeeds(selection.records, recordBySiteId, explicitSeedIds,
                  automaticCandidates, seedBudgetRejected,
                  selectedEstimatedBytes);

  size_t selectedCount = seeds.size();

  if (Expansion.getValue() == "none") {
    for (HotSetSiteDecision &record : selection.records) {
      if (record.role == HotSetRole::Seed)
        continue;
      if (!isSupportedMember(*record.site)) {
        appendReason(record, "hotset-rejected:unsupported-kind");
        continue;
      }
      if (seedBudgetRejected.count(record.site->id) != 0)
        appendReason(record, "hotset-rejected:byte-budget");
      else if (automaticCandidates.count(record.site->id) != 0)
        appendReason(record, "hotset-rejected:seed-limit");
      appendReason(record, "hotset-rejected:expansion-none");
    }
    return selection;
  }

  std::vector<MemberCandidate> memberCandidates =
      discoverMemberCandidates(module, seeds, selection.records);
  std::unordered_set<size_t> candidateRecords;
  for (const MemberCandidate &candidate : memberCandidates) {
    candidateRecords.insert(candidate.recordIndex);
    HotSetSiteDecision &record =
        selection.records[candidate.recordIndex];
    record.groupId = candidate.groupId;
    record.memberAffinity = affinityForAccess(candidate.accessKind);
    record.memberAccessKind = accessKindName(candidate.accessKind);
    record.memberAccessDepth =
        static_cast<int32_t>(candidate.accessDepth);
  }

  for (size_t recordIndex = 0; recordIndex < selection.records.size();
       ++recordIndex) {
    HotSetSiteDecision &record = selection.records[recordIndex];
    if (record.role == HotSetRole::Seed)
      continue;
    if (!isSupportedMember(*record.site)) {
      appendReason(record, "hotset-rejected:unsupported-kind");
      continue;
    }
    if (candidateRecords.count(recordIndex) != 0)
      continue;

    if (seedBudgetRejected.count(record.site->id) != 0)
      appendReason(record, "hotset-rejected:byte-budget");
    else if (automaticCandidates.count(record.site->id) != 0)
      appendReason(record, "hotset-rejected:seed-limit");
    appendReason(record, "hotset-rejected:outside-access-closure");
  }

  std::unordered_map<uint32_t, unsigned> memberCountByGroup;
  for (const MemberCandidate &candidate : memberCandidates) {
    HotSetSiteDecision &record = selection.records[candidate.recordIndex];
    StringRef rejection = memberRejectionReason(record);
    if (!rejection.empty()) {
      appendReason(record, rejection);
      continue;
    }

    if (record.memberAffinity < MemberMinAffinity) {
      appendReason(record,
                   std::string("hotset-rejected:below-member-affinity:score=") +
                       std::to_string(record.memberAffinity));
      continue;
    }

    unsigned &groupMemberCount = memberCountByGroup[candidate.groupId];
    if (MaxMembersPerSeed != 0 &&
        groupMemberCount >= MaxMembersPerSeed) {
      appendReason(record, "hotset-rejected:per-seed-member-limit");
      continue;
    }

    if (selectedCount >= MaxSites) {
      appendReason(record, "hotset-rejected:max-sites");
      continue;
    }

    if (exceedsByteBudget(selectedEstimatedBytes,
                          record.score.estimatedBytes)) {
      appendReason(record, "hotset-rejected:byte-budget");
      continue;
    }

    record.role = HotSetRole::Member;
    appendReason(record,
                 std::string("hotset-member:access-affinity:kind=") +
                     record.memberAccessKind + ":score=" +
                     std::to_string(record.memberAffinity) +
                     ":seed-group=" +
                     std::to_string(candidate.groupId));
    ++selectedCount;
    ++groupMemberCount;
    addEstimatedBytes(selectedEstimatedBytes,
                      record.score.estimatedBytes);
  }

  return selection;
}

} // namespace

const char *hotSetRoleName(HotSetRole role) {
  switch (role) {
  case HotSetRole::Seed:
    return "seed";
  case HotSetRole::Member:
    return "member";
  case HotSetRole::Rejected:
    return "rejected";
  }
  return "rejected";
}

HotSetSelection discoverUseBasedHotSet(Module &module,
                                       ArrayRef<AllocationSite> sites) {
  return buildSelection(module, sites);
}

} // namespace arbiter::llvm::hotset
