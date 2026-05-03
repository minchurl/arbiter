#include "arbiter_runtime.h"

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <limits>

#if ARBITER_HAS_NUMA
#include <numa.h>
#endif

namespace {

constexpr uint64_t kAllocationMagic = 0x4152424954455231ULL;

enum class AllocationBackend : int32_t {
  Malloc = 0,
  Numa = 1,
};

struct ArbiterAllocationHeader {
  uint64_t magic;
  void *rawPtr;
  uint64_t rawSize;
  uint64_t requestedSize;
  int32_t backend;
  int32_t node;
};

static_assert(sizeof(ArbiterAllocationHeader) %
                      alignof(ArbiterAllocationHeader) ==
                  0,
              "allocation header size must preserve header alignment");

struct RuntimeConfig {
  bool hasTargetNode;
  int32_t targetNode;
};

bool normalizeAlignment(uint64_t align, uint64_t &normalized) {
  constexpr uint64_t minAlign =
      sizeof(void *) > alignof(ArbiterAllocationHeader)
          ? sizeof(void *)
          : alignof(ArbiterAllocationHeader);
  if (align < minAlign)
    align = minAlign;

  normalized = minAlign;
  while (normalized < align) {
    if (normalized > std::numeric_limits<uint64_t>::max() / 2)
      return false;
    normalized <<= 1;
  }
  return true;
}

bool checkedAdd(uint64_t lhs, uint64_t rhs, uint64_t &result) {
  if (lhs > std::numeric_limits<uint64_t>::max() - rhs)
    return false;
  result = lhs + rhs;
  return true;
}

bool computeRawSize(uint64_t requestedSize, uint64_t alignment,
                    uint64_t &rawSize) {
  uint64_t effectiveSize = requestedSize == 0 ? 1 : requestedSize;
  uint64_t withHeader = 0;
  if (!checkedAdd(effectiveSize, sizeof(ArbiterAllocationHeader), withHeader))
    return false;
  if (!checkedAdd(withHeader, alignment - 1, rawSize))
    return false;
  return rawSize <= std::numeric_limits<size_t>::max();
}

uintptr_t alignUp(uintptr_t value, uint64_t alignment) {
  uintptr_t mask = static_cast<uintptr_t>(alignment - 1);
  return (value + mask) & ~mask;
}

bool parseTargetNode(int32_t &node) {
  const char *value = std::getenv("ARBITER_TARGET_NODE");
  if (!value || value[0] == '\0')
    return false;

  errno = 0;
  char *end = nullptr;
  long long parsed = std::strtoll(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed < 0 ||
      parsed > std::numeric_limits<int32_t>::max())
    return false;

  node = static_cast<int32_t>(parsed);
  return true;
}

RuntimeConfig loadRuntimeConfig() {
  RuntimeConfig config{false, -1};
  config.hasTargetNode = parseTargetNode(config.targetNode);
  return config;
}

const RuntimeConfig &getRuntimeConfig() {
  static const RuntimeConfig config = loadRuntimeConfig();
  return config;
}

void *finishAllocation(void *rawPtr, uint64_t rawSize, uint64_t requestedSize,
                       uint64_t alignment, AllocationBackend backend,
                       int32_t node) {
  uintptr_t rawAddress = reinterpret_cast<uintptr_t>(rawPtr);
  uintptr_t userAddress =
      alignUp(rawAddress + sizeof(ArbiterAllocationHeader), alignment);
  auto *header = reinterpret_cast<ArbiterAllocationHeader *>(
      userAddress - sizeof(ArbiterAllocationHeader));

  header->magic = kAllocationMagic;
  header->rawPtr = rawPtr;
  header->rawSize = rawSize;
  header->requestedSize = requestedSize;
  header->backend = static_cast<int32_t>(backend);
  header->node = node;

  return reinterpret_cast<void *>(userAddress);
}

void *allocateMalloc(uint64_t rawSize) {
  return std::malloc(static_cast<size_t>(rawSize));
}

#if ARBITER_HAS_NUMA
bool isNumaAvailable() {
  static const bool available = numa_available() >= 0;
  return available;
}
#endif

void *allocateNuma(uint64_t rawSize, int32_t node) {
#if ARBITER_HAS_NUMA
  if (!isNumaAvailable() || node < 0 || node > numa_max_node())
    return nullptr;
  return numa_alloc_onnode(static_cast<size_t>(rawSize), node);
#else
  (void)rawSize;
  (void)node;
  return nullptr;
#endif
}

void freeNuma(void *rawPtr, uint64_t rawSize) {
#if ARBITER_HAS_NUMA
  numa_free(rawPtr, static_cast<size_t>(rawSize));
#else
  (void)rawSize;
  std::free(rawPtr);
#endif
}

} // namespace

extern "C" void *arbiter_alloc(uint64_t size, uint64_t align) {
  uint64_t normalizedAlign = 0;
  if (!normalizeAlignment(align, normalizedAlign))
    return nullptr;

  uint64_t rawSize = 0;
  if (!computeRawSize(size, normalizedAlign, rawSize))
    return nullptr;

  const RuntimeConfig &config = getRuntimeConfig();
  if (config.hasTargetNode) {
    if (void *rawPtr = allocateNuma(rawSize, config.targetNode))
      return finishAllocation(rawPtr, rawSize, size, normalizedAlign,
                              AllocationBackend::Numa, config.targetNode);
  }

  void *rawPtr = allocateMalloc(rawSize);
  if (!rawPtr)
    return nullptr;

  return finishAllocation(rawPtr, rawSize, size, normalizedAlign,
                          AllocationBackend::Malloc, -1);
}

extern "C" void arbiter_dealloc(void *ptr) {
  if (!ptr)
    return;

  auto *header = reinterpret_cast<ArbiterAllocationHeader *>(ptr) - 1;
  if (header->magic != kAllocationMagic) {
    std::free(ptr);
    return;
  }

  void *rawPtr = header->rawPtr;
  uint64_t rawSize = header->rawSize;
  AllocationBackend backend =
      static_cast<AllocationBackend>(header->backend);
  header->magic = 0;

  if (backend == AllocationBackend::Numa)
    freeNuma(rawPtr, rawSize);
  else
    std::free(rawPtr);
}
