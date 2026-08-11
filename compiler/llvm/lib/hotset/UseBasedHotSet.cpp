#include "UseBasedHotSet.h"

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

constexpr size_t kMaxTraceStatesPerHITMSeed = 4096;

struct HITMSeed {
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

void validateDiscoveryOptions(const HotSetPolicy &policy) {
  StringRef expansion = policy.expansion;
  if (expansion != "none" && expansion != "use") {
    failConfig(Twine("invalid expansion '") + expansion +
               "'; expected none or use");
  }

  unsigned affinity = policy.memberMinAffinity;
  if (affinity != 1 && affinity != 3 && affinity != 5) {
    failConfig(Twine("invalid member-min-affinity ") + Twine(affinity) +
               "; expected 1, 3, or 5");
  }
  if (policy.memberMaxCallDepth > 4)
    failConfig("member-max-call-depth must be between 0 and 4");
  if (policy.memberMaxLoadDepth > 4)
    failConfig("member-max-load-depth must be between 0 and 4");
}

bool exceedsByteBudget(uint64_t selectedBytes, uint64_t nextBytes,
                       const HotSetPolicy &policy) {
  uint64_t limit = policy.maxEstimatedBytes;
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
    Module &module, const HITMSeed &seed,
    ArrayRef<HotSetSiteDecision> records,
    const std::unordered_map<const Value *, size_t> &allocationByValue,
    const HotSetPolicy &policy) {
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
    if (visited.find(key) != visited.end())
      return;
    if (visited.size() >= kMaxTraceStatesPerHITMSeed)
      return;
    visited.insert(std::move(key));
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
          if (nextLoadDepth > policy.memberMaxLoadDepth)
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
            callee && state.callDepth < policy.memberMaxCallDepth &&
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
discoverMemberCandidates(Module &module, ArrayRef<HITMSeed> seeds,
                         ArrayRef<HotSetSiteDecision> records,
                         const HotSetPolicy &policy) {
  std::unordered_map<const Value *, size_t> allocationByValue;
  for (size_t recordIndex = 0; recordIndex < records.size(); ++recordIndex) {
    const HotSetSiteDecision &record = records[recordIndex];
    if (isSupportedMember(*record.site) && record.site->call)
      allocationByValue.emplace(record.site->call, recordIndex);
  }

  std::unordered_map<size_t, MemberCandidate> bestByRecord;
  for (const HITMSeed &seed : seeds) {
    for (const MemberCandidate &candidate :
         discoverSeedMemberCandidates(module, seed, records,
                                      allocationByValue, policy)) {
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
              unsigned leftAffinity =
                  affinityForAccess(left.accessKind);
              unsigned rightAffinity =
                  affinityForAccess(right.accessKind);
              if (leftAffinity != rightAffinity)
                return leftAffinity > rightAffinity;
              if (left.accessDepth != right.accessDepth)
                return left.accessDepth < right.accessDepth;
              if (left.groupId != right.groupId)
                return left.groupId < right.groupId;
              return records[left.recordIndex].site->id <
                     records[right.recordIndex].site->id;
            });
  return candidates;
}

StringRef memberRejectionReason(const HotSetSiteDecision &record,
                                const HotSetPolicy &policy) {
  if (isHeapAllocation(record.site->kind))
    return StringRef();

  if (isMMapAllocation(record.site->kind)) {
    if (!policy.includeMMap)
      return "hotset-rejected:mmap-disabled";
    if (!record.site->call || !isAnonymousMMap(*record.site->call))
      return "hotset-rejected:mmap-not-anonymous";
    return StringRef();
  }

  return "hotset-rejected:unsupported-kind";
}

HotSetSelection buildSelection(Module &module,
                               const HITMSeedSelection &hitmSeeds,
                               const HotSetPolicy &policy) {
  validateDiscoveryOptions(policy);

  HotSetSelection selection;
  selection.records.reserve(hitmSeeds.records.size());
  std::vector<HITMSeed> seeds;
  for (const HITMSeedDecision &hitmRecord : hitmSeeds.records) {
    HotSetSiteDecision record;
    record.site = hitmRecord.site;
    record.score = hitmRecord.score;
    // Dynamic byte estimates belong to the final hot-set budget and must not
    // influence which HITM seeds Stage 1 selects.
    if (record.score.hasDynamicSize)
      record.score.estimatedBytes = policy.dynamicSizeEstimate;
    record.reason = hitmRecord.score.reasons;
    if (hitmRecord.selected) {
      record.role = HotSetRole::Seed;
      record.groupId = hitmRecord.groupId;
      seeds.push_back({selection.records.size(), hitmRecord.groupId});
    }
    selection.records.push_back(std::move(record));
  }

  if (seeds.size() > policy.maxSites) {
    failConfig(Twine("selected HITM seeds exceed hotset max-sites ") +
               Twine(policy.maxSites));
  }

  uint64_t selectedEstimatedBytes = 0;
  for (const HITMSeed &seed : seeds) {
    const HotSetSiteDecision &record = selection.records[seed.recordIndex];
    if (exceedsByteBudget(selectedEstimatedBytes,
                          record.score.estimatedBytes, policy)) {
      failConfig(
          Twine("selected HITM seeds exceed hotset max-estimated-bytes ") +
          Twine(policy.maxEstimatedBytes));
    }
    addEstimatedBytes(selectedEstimatedBytes, record.score.estimatedBytes);
  }

  size_t selectedCount = seeds.size();

  if (policy.expansion == "none") {
    for (HotSetSiteDecision &record : selection.records) {
      if (record.role == HotSetRole::Seed)
        continue;
      if (!isSupportedMember(*record.site)) {
        appendReason(record, "hotset-rejected:unsupported-kind");
        continue;
      }
      appendReason(record, "hotset-rejected:expansion-none");
    }
    return selection;
  }

  std::vector<MemberCandidate> memberCandidates =
      discoverMemberCandidates(module, seeds, selection.records, policy);
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

    appendReason(record, "hotset-rejected:outside-access-closure");
  }

  std::unordered_map<uint32_t, unsigned> memberCountByGroup;
  for (const MemberCandidate &candidate : memberCandidates) {
    HotSetSiteDecision &record = selection.records[candidate.recordIndex];
    StringRef rejection = memberRejectionReason(record, policy);
    if (!rejection.empty()) {
      appendReason(record, rejection);
      continue;
    }

    if (record.memberAffinity < policy.memberMinAffinity) {
      appendReason(record, "hotset-rejected:below-member-affinity");
      continue;
    }

    unsigned &groupMemberCount = memberCountByGroup[candidate.groupId];
    if (policy.maxMembersPerSeed != 0 &&
        groupMemberCount >= policy.maxMembersPerSeed) {
      appendReason(record, "hotset-rejected:per-seed-member-limit");
      continue;
    }

    if (selectedCount >= policy.maxSites) {
      appendReason(record, "hotset-rejected:max-sites");
      continue;
    }

    if (exceedsByteBudget(selectedEstimatedBytes,
                          record.score.estimatedBytes, policy)) {
      appendReason(record, "hotset-rejected:byte-budget");
      continue;
    }

    record.role = HotSetRole::Member;
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
                                       const HITMSeedSelection &hitmSeeds,
                                       const HotSetPolicy &policy) {
  return buildSelection(module, hitmSeeds, policy);
}

} // namespace arbiter::llvm::hotset
