#include "arbiter_runtime_site.h"

#include "arbiter_side_table.h"
#include "arbiter_slab_arena.h"

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <sys/mman.h>

#if ARBITER_HAS_NUMA
#include <numa.h>
#endif

namespace {

using arbiter::runtime::SideTableBackend;
using arbiter::runtime::SideTableEntry;
using arbiter::runtime::SideTableKind;

constexpr int32_t kNoTargetNode = -1;

struct RuntimeConfig {
  enum class HeapBackend : uint8_t {
    Direct,
    Arena,
  };

  bool valid;
  bool hasTargetNode;
  int32_t targetNode;
  HeapBackend heapBackend;
  bool arenaStrict;
};

struct BackendAllocation {
  void *ptr;
  SideTableBackend backend;
  int32_t node;
};

bool checkedMul(uint64_t lhs, uint64_t rhs, uint64_t &result) {
  if (rhs != 0 && lhs > std::numeric_limits<uint64_t>::max() / rhs)
    return false;
  result = lhs * rhs;
  return true;
}

bool fitsSizeT(uint64_t size) {
  return size <= std::numeric_limits<size_t>::max();
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

bool parseToggle(const char *name, bool defaultValue, bool &result) {
  const char *value = std::getenv(name);
  if (!value || value[0] == '\0') {
    result = defaultValue;
    return true;
  }
  if (std::strcmp(value, "0") == 0) {
    result = false;
    return true;
  }
  if (std::strcmp(value, "1") == 0) {
    result = true;
    return true;
  }

  std::fprintf(stderr, "arbiter-runtime: %s must be 0 or 1: %s\n", name,
               value);
  return false;
}

bool parseHeapBackend(RuntimeConfig::HeapBackend &backend) {
  const char *value = std::getenv("ARBITER_HEAP_BACKEND");
  if (!value || value[0] == '\0' || std::strcmp(value, "direct") == 0) {
    backend = RuntimeConfig::HeapBackend::Direct;
    return true;
  }
  if (std::strcmp(value, "arena") == 0) {
    backend = RuntimeConfig::HeapBackend::Arena;
    return true;
  }

  std::fprintf(stderr,
               "arbiter-runtime: ARBITER_HEAP_BACKEND must be direct or "
               "arena: %s\n",
               value);
  return false;
}

RuntimeConfig loadRuntimeConfig() {
  RuntimeConfig config{true, false, kNoTargetNode,
                       RuntimeConfig::HeapBackend::Direct, true};
  config.hasTargetNode = parseTargetNode(config.targetNode);
  config.valid = parseHeapBackend(config.heapBackend) &&
                 parseToggle("ARBITER_ARENA_STRICT", true,
                             config.arenaStrict);
  if (config.heapBackend == RuntimeConfig::HeapBackend::Arena &&
      !config.hasTargetNode) {
    std::fprintf(stderr,
                 "arbiter-runtime: ARBITER_TARGET_NODE is required when "
                 "ARBITER_HEAP_BACKEND=arena\n");
    config.valid = false;
  }
  return config;
}

const RuntimeConfig &getRuntimeConfig() {
  static const RuntimeConfig config = loadRuntimeConfig();
  return config;
}

#if ARBITER_HAS_NUMA
bool isNumaAvailable() {
  static const bool available = numa_available() >= 0;
  return available;
}
#endif

void *allocateMalloc(uint64_t size) {
  if (!fitsSizeT(size))
    return nullptr;

  return std::malloc(static_cast<size_t>(size));
}

void *allocateNuma(uint64_t size, int32_t node) {
#if ARBITER_HAS_NUMA
  if (!fitsSizeT(size))
    return nullptr;
  if (!isNumaAvailable() || node < 0 || node > numa_max_node())
    return nullptr;
  return numa_alloc_onnode(static_cast<size_t>(size), node);
#else
  (void)size;
  (void)node;
  return nullptr;
#endif
}

BackendAllocation tryAllocateOnTargetNode(uint64_t size) {
  const RuntimeConfig &config = getRuntimeConfig();
  if (!config.hasTargetNode)
    return {nullptr, SideTableBackend::Malloc, kNoTargetNode};

  void *ptr = allocateNuma(size, config.targetNode);
  if (!ptr)
    return {nullptr, SideTableBackend::Malloc, kNoTargetNode};

  return {ptr, SideTableBackend::Numa, config.targetNode};
}

BackendAllocation allocateHeap(uint64_t size) {
  BackendAllocation allocation = tryAllocateOnTargetNode(size);
  if (allocation.ptr)
    return allocation;

  return {allocateMalloc(size), SideTableBackend::Malloc, kNoTargetNode};
}

void freeNuma(void *ptr, uint64_t size) {
#if ARBITER_HAS_NUMA
  numa_free(ptr, static_cast<size_t>(size));
#else
  (void)size;
  std::free(ptr);
#endif
}

int unmapRaw(void *ptr, uint64_t size) {
  if (!fitsSizeT(size))
    return -1;
  return munmap(ptr, static_cast<size_t>(size));
}

void releaseTrackedAllocation(void *ptr, const SideTableEntry &entry) {
  switch (entry.backend) {
  case SideTableBackend::Malloc:
    std::free(ptr);
    return;
  case SideTableBackend::Numa:
    freeNuma(ptr, entry.size);
    return;
  case SideTableBackend::MMap:
    unmapRaw(ptr, entry.size);
    return;
  }
}

bool releaseIfTracked(void *ptr) {
  SideTableEntry entry{};
  if (!arbiter::runtime::sideTableTake(ptr, entry))
    return false;

  releaseTrackedAllocation(ptr, entry);
  return true;
}

bool releaseHeapAllocation(void *ptr) {
  const RuntimeConfig &config = getRuntimeConfig();
  if (config.heapBackend == RuntimeConfig::HeapBackend::Arena) {
    switch (arbiter::runtime::slabArenaDeallocate(ptr)) {
    case arbiter::runtime::SlabArenaDeallocation::Released:
      return true;
    case arbiter::runtime::SlabArenaDeallocation::Invalid:
      std::fprintf(stderr,
                   "arbiter-runtime: invalid or duplicate free inside the "
                   "slab arena\n");
      std::abort();
    case arbiter::runtime::SlabArenaDeallocation::NotOwned:
      break;
    }

    // Strict arena mode never falls back to individually tracked heap
    // allocations. Avoid a mutex/hash lookup for every ordinary free/delete.
    if (config.arenaStrict)
      return false;
  }

  return releaseIfTracked(ptr);
}

SideTableEntry makeEntry(SideTableKind kind,
                         const BackendAllocation &allocation, uint64_t size,
                         uint32_t siteId) {
  SideTableEntry entry{};
  entry.kind = kind;
  entry.backend = allocation.backend;
  entry.size = size;
  entry.siteId = siteId;
  entry.node = allocation.node;
  return entry;
}

bool trackOrRelease(void *ptr, const SideTableEntry &entry) {
  if (arbiter::runtime::sideTableInsert(ptr, entry))
    return true;

  releaseTrackedAllocation(ptr, entry);
  return false;
}

} // namespace

extern "C" void *arbiter_alloc_site(uint64_t size, uint64_t align,
                                    uint32_t site_id, uint32_t reserved) {
  (void)reserved;

  const RuntimeConfig &config = getRuntimeConfig();
  if (!config.valid || !fitsSizeT(size))
    return nullptr;

  if (config.heapBackend == RuntimeConfig::HeapBackend::Arena) {
    arbiter::runtime::SlabArenaFailure failure =
        arbiter::runtime::SlabArenaFailure::None;
    void *ptr = arbiter::runtime::slabArenaAllocate(
        size, align, site_id, config.targetNode, failure);
    if (ptr)
      return ptr;

    arbiter::runtime::slabArenaRecordFallback(failure);
    if (config.arenaStrict)
      return nullptr;
  }

  BackendAllocation allocation = allocateHeap(size);
  if (!allocation.ptr)
    return nullptr;

  SideTableEntry entry = makeEntry(SideTableKind::Heap, allocation, size,
                                   site_id);
  if (!trackOrRelease(allocation.ptr, entry))
    return nullptr;

  return allocation.ptr;
}

extern "C" void *arbiter_calloc_site(uint64_t count, uint64_t elem_size,
                                     uint64_t align, uint32_t site_id,
                                     uint32_t reserved) {
  uint64_t size = 0;
  if (!checkedMul(count, elem_size, size))
    return nullptr;
  if (!fitsSizeT(size))
    return nullptr;

  void *ptr = arbiter_alloc_site(size, align, site_id, reserved);
  if (!ptr)
    return nullptr;

  std::memset(ptr, 0, static_cast<size_t>(size));
  return ptr;
}

extern "C" void *arbiter_mmap_site(uint64_t size, int prot, int mmap_flags,
                                   uint32_t site_id, uint32_t reserved) {
  (void)reserved;
  if (size == 0 || !fitsSizeT(size))
    return MAP_FAILED;

  BackendAllocation target = tryAllocateOnTargetNode(size);
  if (target.ptr) {
    std::memset(target.ptr, 0, static_cast<size_t>(size));
    SideTableEntry entry =
        makeEntry(SideTableKind::MMap, target, size, site_id);
    if (trackOrRelease(target.ptr, entry))
      return target.ptr;
    return MAP_FAILED;
  }

  void *ptr = mmap(nullptr, static_cast<size_t>(size), prot, mmap_flags, -1, 0);
  if (ptr == MAP_FAILED)
    return MAP_FAILED;

  BackendAllocation allocation{ptr, SideTableBackend::MMap, kNoTargetNode};
  SideTableEntry entry =
      makeEntry(SideTableKind::MMap, allocation, size, site_id);
  if (trackOrRelease(ptr, entry))
    return ptr;

  return MAP_FAILED;
}

extern "C" void arbiter_free_maybe(void *ptr) {
  if (!ptr)
    return;

  if (releaseHeapAllocation(ptr))
    return;

  std::free(ptr);
}

extern "C" void arbiter_cxx_delete_maybe(void *ptr) {
  if (!ptr)
    return;

  if (releaseHeapAllocation(ptr))
    return;

  ::operator delete(ptr);
}

extern "C" void arbiter_cxx_delete_array_maybe(void *ptr) {
  if (!ptr)
    return;

  if (releaseHeapAllocation(ptr))
    return;

  ::operator delete[](ptr);
}

extern "C" int arbiter_munmap_maybe(void *ptr, uint64_t size) {
  if (!ptr)
    return unmapRaw(ptr, size);

  if (releaseIfTracked(ptr))
    return 0;

  return unmapRaw(ptr, size);
}
