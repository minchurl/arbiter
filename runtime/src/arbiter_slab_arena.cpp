#include "arbiter_slab_arena.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cinttypes>
#include <climits>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <mutex>
#include <new>
#include <utility>
#include <vector>

#include <sys/mman.h>
#include <unistd.h>

#if ARBITER_HAS_NUMA_ARENA
#include <numa.h>
#include <numaif.h>
#endif

namespace arbiter::runtime {
namespace {

constexpr uint64_t kDefaultSlabBytes = 2ULL * 1024ULL * 1024ULL;
constexpr uint64_t kDefaultReserveBytes = 4ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr uint64_t kDefaultSlotAlignment = 64;
constexpr uint32_t kMaxSiteId = 65535;
constexpr size_t kBitsPerWord = sizeof(uint64_t) * CHAR_BIT;

class SiteArena;

struct Slab {
  SiteArena *owner = nullptr;
  unsigned char *base = nullptr;
  size_t capacity = 0;
  std::atomic<size_t> nextSlot{0};
  size_t bitmapWords = 0;
  std::atomic<uint64_t> *allocated = nullptr;
};

struct RecycledSlot {
  void *ptr;
  Slab *slab;
};

bool isPowerOfTwo(uint64_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

bool checkedRoundUp(uint64_t value, uint64_t alignment, uint64_t &result) {
  if (!isPowerOfTwo(alignment))
    return false;
  uint64_t mask = alignment - 1;
  if (value > std::numeric_limits<uint64_t>::max() - mask)
    return false;
  result = (value + mask) & ~mask;
  return true;
}

#if ARBITER_HAS_NUMA_ARENA
bool parsePositiveBytes(const char *name, uint64_t defaultValue,
                        uint64_t &value) {
  const char *raw = std::getenv(name);
  if (!raw || raw[0] == '\0') {
    value = defaultValue;
    return true;
  }

  errno = 0;
  char *end = nullptr;
  unsigned long long parsed = std::strtoull(raw, &end, 10);
  if (errno != 0 || end == raw || *end != '\0' || parsed == 0) {
    std::fprintf(stderr, "arbiter-arena: invalid %s=%s\n", name, raw);
    return false;
  }

  value = static_cast<uint64_t>(parsed);
  return true;
}

bool parseToggle(const char *name, bool defaultValue, bool &value) {
  const char *raw = std::getenv(name);
  if (!raw || raw[0] == '\0') {
    value = defaultValue;
    return true;
  }
  if (std::strcmp(raw, "0") == 0) {
    value = false;
    return true;
  }
  if (std::strcmp(raw, "1") == 0) {
    value = true;
    return true;
  }

  std::fprintf(stderr, "arbiter-arena: %s must be 0 or 1: %s\n", name, raw);
  return false;
}
#endif

void updatePeak(std::atomic<uint64_t> &peak, uint64_t value) {
  uint64_t observed = peak.load(std::memory_order_relaxed);
  while (observed < value &&
         !peak.compare_exchange_weak(observed, value, std::memory_order_relaxed,
                                     std::memory_order_relaxed)) {
  }
}

class ArenaManager {
public:
  static ArenaManager *create(int32_t node);

  ArenaManager(const ArenaManager &) = delete;
  ArenaManager &operator=(const ArenaManager &) = delete;

  void *allocate(uint64_t size, uint64_t align, uint32_t siteId,
                 SlabArenaFailure &failure);
  SlabArenaDeallocation deallocate(void *ptr);
  Slab *allocateSlab(SiteArena *owner, size_t capacity);
  void recordFallback(SlabArenaFailure failure);
  void report() const;

  uint64_t slabBytes() const { return slabBytes_; }
  uint64_t slotAlignment() const { return slotAlignment_; }

private:
  ArenaManager(int32_t node, uint64_t slabBytes, uint64_t reserveBytes,
               uint64_t slotAlignment, uint64_t pageSize, bool reportEnabled,
               unsigned char *region, size_t slabCount,
               std::atomic<Slab *> *slabOwners,
               std::atomic<SiteArena *> *siteArenas)
      : node_(node), slabBytes_(slabBytes), reserveBytes_(reserveBytes),
        slotAlignment_(slotAlignment), pageSize_(pageSize),
        reportEnabled_(reportEnabled), region_(region), slabCount_(slabCount),
        slabOwners_(slabOwners), siteArenas_(siteArenas) {}

  SiteArena *getOrCreateSiteArena(uint64_t size, uint64_t align,
                                  uint32_t siteId, SlabArenaFailure &failure);
  void reportResidency() const;

  int32_t node_;
  uint64_t slabBytes_;
  uint64_t reserveBytes_;
  uint64_t slotAlignment_;
  uint64_t pageSize_;
  bool reportEnabled_;
  unsigned char *region_;
  size_t slabCount_;
  std::atomic<Slab *> *slabOwners_;
  std::atomic<SiteArena *> *siteArenas_;
  std::atomic<size_t> nextSlab_{0};
  mutable std::mutex siteMutex_;
  std::atomic<uint64_t> fallbackUnavailable_{0};
  std::atomic<uint64_t> fallbackUnsupported_{0};
  std::atomic<uint64_t> fallbackExhausted_{0};
};

class SiteArena {
public:
  SiteArena(ArenaManager &manager, uint32_t siteId, uint64_t objectBytes,
            uint64_t requestedAlignment, uint64_t effectiveAlignment,
            uint64_t slotBytes)
      : manager_(manager), siteId_(siteId), objectBytes_(objectBytes),
        requestedAlignment_(requestedAlignment),
        effectiveAlignment_(effectiveAlignment), slotBytes_(slotBytes) {}

  void *allocate(SlabArenaFailure &failure) {
    Slab *slab = currentSlab_.load(std::memory_order_acquire);
    if (slab) {
      if (void *ptr = allocateFresh(*slab)) {
        recordAllocation();
        failure = SlabArenaFailure::None;
        return ptr;
      }
    }

    return allocateSlow(failure);
  }

  SlabArenaDeallocation deallocate(void *ptr, Slab &slab) {
    uintptr_t address = reinterpret_cast<uintptr_t>(ptr);
    uintptr_t base = reinterpret_cast<uintptr_t>(slab.base);
    if (address < base)
      return SlabArenaDeallocation::Invalid;

    uint64_t offset = static_cast<uint64_t>(address - base);
    if (offset % slotBytes_ != 0)
      return SlabArenaDeallocation::Invalid;

    uint64_t slot = offset / slotBytes_;
    if (slot >= slab.capacity)
      return SlabArenaDeallocation::Invalid;

    size_t word = static_cast<size_t>(slot / kBitsPerWord);
    uint64_t bit = uint64_t{1} << (slot % kBitsPerWord);
    uint64_t previous =
        slab.allocated[word].fetch_and(~bit, std::memory_order_acq_rel);
    if ((previous & bit) == 0)
      return SlabArenaDeallocation::Invalid;

    {
      std::lock_guard<std::mutex> lock(slowMutex_);
      recycled_.push_back({ptr, &slab});
    }

    frees_.fetch_add(1, std::memory_order_relaxed);
    live_.fetch_sub(1, std::memory_order_relaxed);
    return SlabArenaDeallocation::Released;
  }

  bool matches(uint64_t size, uint64_t requestedAlignment) const {
    return size == objectBytes_ && requestedAlignment == requestedAlignment_;
  }

  uint32_t siteId() const { return siteId_; }
  uint64_t objectBytes() const { return objectBytes_; }
  uint64_t requestedAlignment() const { return requestedAlignment_; }
  uint64_t effectiveAlignment() const { return effectiveAlignment_; }
  uint64_t slotBytes() const { return slotBytes_; }
  uint64_t allocations() const {
    return allocations_.load(std::memory_order_relaxed);
  }
  uint64_t frees() const { return frees_.load(std::memory_order_relaxed); }
  uint64_t live() const { return live_.load(std::memory_order_relaxed); }
  uint64_t peakLive() const {
    return peakLive_.load(std::memory_order_relaxed);
  }
  uint64_t requestedBytes() const {
    return requestedBytes_.load(std::memory_order_relaxed);
  }
  uint64_t slotBytesTotal() const {
    return slotBytesTotal_.load(std::memory_order_relaxed);
  }
  uint64_t assignedSlabs() const {
    return assignedSlabs_.load(std::memory_order_relaxed);
  }

private:
  void *allocateFresh(Slab &slab) {
    size_t slot = slab.nextSlot.fetch_add(1, std::memory_order_relaxed);
    if (slot >= slab.capacity)
      return nullptr;

    size_t word = slot / kBitsPerWord;
    uint64_t bit = uint64_t{1} << (slot % kBitsPerWord);
    uint64_t previous =
        slab.allocated[word].fetch_or(bit, std::memory_order_acq_rel);
    if ((previous & bit) != 0) {
      std::fprintf(stderr,
                   "arbiter-arena: internal allocation bitmap conflict at "
                   "site=%u slot=%zu\n",
                   siteId_, slot);
      std::abort();
    }

    return slab.base + slot * slotBytes_;
  }

  void *allocateRecycled() {
    if (recycled_.empty())
      return nullptr;

    RecycledSlot recycled = recycled_.back();
    recycled_.pop_back();

    uintptr_t address = reinterpret_cast<uintptr_t>(recycled.ptr);
    uintptr_t base = reinterpret_cast<uintptr_t>(recycled.slab->base);
    size_t slot = static_cast<size_t>((address - base) / slotBytes_);
    size_t word = slot / kBitsPerWord;
    uint64_t bit = uint64_t{1} << (slot % kBitsPerWord);
    uint64_t previous =
        recycled.slab->allocated[word].fetch_or(bit, std::memory_order_acq_rel);
    if ((previous & bit) != 0) {
      std::fprintf(stderr,
                   "arbiter-arena: internal recycled-slot conflict at "
                   "site=%u slot=%zu\n",
                   siteId_, slot);
      std::abort();
    }

    return recycled.ptr;
  }

  void *allocateSlow(SlabArenaFailure &failure) {
    std::lock_guard<std::mutex> lock(slowMutex_);

    if (void *ptr = allocateRecycled()) {
      recordAllocation();
      failure = SlabArenaFailure::None;
      return ptr;
    }

    Slab *slab = currentSlab_.load(std::memory_order_acquire);
    if (slab) {
      if (void *ptr = allocateFresh(*slab)) {
        recordAllocation();
        failure = SlabArenaFailure::None;
        return ptr;
      }
    }

    size_t capacity = static_cast<size_t>(manager_.slabBytes() / slotBytes_);
    Slab *newSlab = manager_.allocateSlab(this, capacity);
    if (!newSlab) {
      failure = SlabArenaFailure::Exhausted;
      return nullptr;
    }

    assignedSlabs_.fetch_add(1, std::memory_order_relaxed);
    currentSlab_.store(newSlab, std::memory_order_release);
    void *ptr = allocateFresh(*newSlab);
    if (!ptr) {
      failure = SlabArenaFailure::Exhausted;
      return nullptr;
    }

    recordAllocation();
    failure = SlabArenaFailure::None;
    return ptr;
  }

  void recordAllocation() {
    allocations_.fetch_add(1, std::memory_order_relaxed);
    requestedBytes_.fetch_add(objectBytes_, std::memory_order_relaxed);
    slotBytesTotal_.fetch_add(slotBytes_, std::memory_order_relaxed);
    uint64_t live = live_.fetch_add(1, std::memory_order_relaxed) + 1;
    updatePeak(peakLive_, live);
  }

  ArenaManager &manager_;
  uint32_t siteId_;
  uint64_t objectBytes_;
  uint64_t requestedAlignment_;
  uint64_t effectiveAlignment_;
  uint64_t slotBytes_;
  std::atomic<Slab *> currentSlab_{nullptr};
  std::mutex slowMutex_;
  std::vector<RecycledSlot> recycled_;
  std::atomic<uint64_t> allocations_{0};
  std::atomic<uint64_t> frees_{0};
  std::atomic<uint64_t> live_{0};
  std::atomic<uint64_t> peakLive_{0};
  std::atomic<uint64_t> requestedBytes_{0};
  std::atomic<uint64_t> slotBytesTotal_{0};
  std::atomic<uint64_t> assignedSlabs_{0};
};

std::atomic<ArenaManager *> &managerSlot() {
  static std::atomic<ArenaManager *> manager{nullptr};
  return manager;
}

std::mutex &managerMutex() {
  static auto *mutex = new std::mutex();
  return *mutex;
}

void reportAtExit() {
  ArenaManager *manager = managerSlot().load(std::memory_order_acquire);
  if (manager)
    manager->report();
}

ArenaManager *getOrCreateManager(int32_t node) {
  ArenaManager *manager = managerSlot().load(std::memory_order_acquire);
  if (manager)
    return manager;

  std::lock_guard<std::mutex> lock(managerMutex());
  manager = managerSlot().load(std::memory_order_relaxed);
  if (manager)
    return manager;

  manager = ArenaManager::create(node);
  if (!manager)
    return nullptr;

  managerSlot().store(manager, std::memory_order_release);
  std::atexit(reportAtExit);
  return manager;
}

ArenaManager *ArenaManager::create(int32_t node) {
#if !ARBITER_HAS_NUMA_ARENA
  (void)node;
  std::fprintf(stderr,
               "arbiter-arena: unavailable; Linux NUMA policy support was "
               "not built\n");
  return nullptr;
#else
  if (numa_available() < 0 || node < 0 || node > numa_max_node()) {
    std::fprintf(stderr, "arbiter-arena: invalid or unavailable NUMA node %d\n",
                 node);
    return nullptr;
  }

  long pageSizeRaw = ::sysconf(_SC_PAGESIZE);
  if (pageSizeRaw <= 0) {
    std::fprintf(stderr, "arbiter-arena: failed to query the page size\n");
    return nullptr;
  }
  uint64_t pageSize = static_cast<uint64_t>(pageSizeRaw);

  uint64_t slabBytes = 0;
  uint64_t reserveBytes = 0;
  uint64_t slotAlignment = 0;
  bool reportEnabled = false;
  if (!parsePositiveBytes("ARBITER_ARENA_SLAB_BYTES", kDefaultSlabBytes,
                          slabBytes) ||
      !parsePositiveBytes("ARBITER_ARENA_RESERVE_BYTES", kDefaultReserveBytes,
                          reserveBytes) ||
      !parsePositiveBytes("ARBITER_ARENA_SLOT_ALIGNMENT", kDefaultSlotAlignment,
                          slotAlignment) ||
      !parseToggle("ARBITER_ARENA_REPORT", false, reportEnabled))
    return nullptr;

  if (!isPowerOfTwo(slotAlignment) ||
      slotAlignment < alignof(std::max_align_t) || slotAlignment > pageSize) {
    std::fprintf(stderr,
                 "arbiter-arena: ARBITER_ARENA_SLOT_ALIGNMENT must be a "
                 "power of two between %zu and %" PRIu64 "\n",
                 alignof(std::max_align_t), pageSize);
    return nullptr;
  }
  if (slabBytes < pageSize || slabBytes % pageSize != 0) {
    std::fprintf(stderr,
                 "arbiter-arena: ARBITER_ARENA_SLAB_BYTES must be a positive "
                 "multiple of the page size (%" PRIu64 ")\n",
                 pageSize);
    return nullptr;
  }

  reserveBytes = (reserveBytes / slabBytes) * slabBytes;
  if (reserveBytes < slabBytes ||
      reserveBytes >
          static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
    std::fprintf(stderr,
                 "arbiter-arena: ARBITER_ARENA_RESERVE_BYTES is too small or "
                 "too large\n");
    return nullptr;
  }

  int mmapFlags = MAP_PRIVATE | MAP_ANONYMOUS;
#ifdef MAP_NORESERVE
  mmapFlags |= MAP_NORESERVE;
#endif
  void *mapping = mmap(nullptr, static_cast<size_t>(reserveBytes),
                       PROT_READ | PROT_WRITE, mmapFlags, -1, 0);
  if (mapping == MAP_FAILED) {
    std::fprintf(
        stderr, "arbiter-arena: mmap of %" PRIu64 " reserve bytes failed: %s\n",
        reserveBytes, std::strerror(errno));
    return nullptr;
  }

  bitmask *nodeMask = numa_allocate_nodemask();
  if (!nodeMask) {
    munmap(mapping, static_cast<size_t>(reserveBytes));
    std::fprintf(stderr, "arbiter-arena: NUMA node-mask allocation failed\n");
    return nullptr;
  }
  numa_bitmask_clearall(nodeMask);
  numa_bitmask_setbit(nodeMask, static_cast<unsigned int>(node));
  // libnuma passes bitmask::size + 1 to the kernel's historical maxnode ABI.
  // A minimal node+1 mask is rejected by some kernels even for node zero.
  unsigned long maxNode = static_cast<unsigned long>(nodeMask->size) + 1;
  if (mbind(mapping, static_cast<unsigned long>(reserveBytes), MPOL_BIND,
            nodeMask->maskp, maxNode, 0) != 0) {
    int savedErrno = errno;
    numa_bitmask_free(nodeMask);
    munmap(mapping, static_cast<size_t>(reserveBytes));
    std::fprintf(stderr, "arbiter-arena: mbind reserve to node %d failed: %s\n",
                 node, std::strerror(savedErrno));
    return nullptr;
  }
  numa_bitmask_free(nodeMask);

  size_t slabCount = static_cast<size_t>(reserveBytes / slabBytes);
  auto *slabOwners = new (std::nothrow) std::atomic<Slab *>[slabCount];
  auto *siteArenas =
      new (std::nothrow) std::atomic<SiteArena *>[kMaxSiteId + 1];
  if (!slabOwners || !siteArenas) {
    delete[] slabOwners;
    delete[] siteArenas;
    munmap(mapping, static_cast<size_t>(reserveBytes));
    std::fprintf(stderr, "arbiter-arena: metadata allocation failed\n");
    return nullptr;
  }

  for (size_t i = 0; i < slabCount; ++i)
    slabOwners[i].store(nullptr, std::memory_order_relaxed);
  for (size_t i = 0; i <= kMaxSiteId; ++i)
    siteArenas[i].store(nullptr, std::memory_order_relaxed);

  auto *manager = new (std::nothrow) ArenaManager(
      node, slabBytes, reserveBytes, slotAlignment, pageSize, reportEnabled,
      static_cast<unsigned char *>(mapping), slabCount, slabOwners, siteArenas);
  if (!manager) {
    delete[] slabOwners;
    delete[] siteArenas;
    munmap(mapping, static_cast<size_t>(reserveBytes));
    std::fprintf(stderr, "arbiter-arena: manager allocation failed\n");
    return nullptr;
  }

  return manager;
#endif
}

SiteArena *ArenaManager::getOrCreateSiteArena(uint64_t size, uint64_t align,
                                              uint32_t siteId,
                                              SlabArenaFailure &failure) {
  if (siteId > kMaxSiteId || size == 0) {
    failure = SlabArenaFailure::Unsupported;
    return nullptr;
  }

  uint64_t requestedAlignment = align == 0 ? alignof(std::max_align_t) : align;
  // mmap guarantees page alignment for the reserved region, and every slab
  // starts on a page boundary. Reject stronger alignments instead of claiming
  // an alignment the mapping cannot guarantee.
  if (!isPowerOfTwo(requestedAlignment) || requestedAlignment > pageSize_) {
    failure = SlabArenaFailure::Unsupported;
    return nullptr;
  }

  uint64_t effectiveAlignment =
      std::max<uint64_t>(requestedAlignment, slotAlignment_);
  if (effectiveAlignment > slabBytes_) {
    failure = SlabArenaFailure::Unsupported;
    return nullptr;
  }

  uint64_t minimumSlot = std::max<uint64_t>(size, sizeof(void *));
  uint64_t slotBytes = 0;
  if (!checkedRoundUp(minimumSlot, effectiveAlignment, slotBytes) ||
      slotBytes == 0 || slotBytes > slabBytes_ / 2) {
    failure = SlabArenaFailure::Unsupported;
    return nullptr;
  }

  SiteArena *arena = siteArenas_[siteId].load(std::memory_order_acquire);
  if (arena) {
    if (!arena->matches(size, requestedAlignment)) {
      failure = SlabArenaFailure::Unsupported;
      return nullptr;
    }
    failure = SlabArenaFailure::None;
    return arena;
  }

  std::lock_guard<std::mutex> lock(siteMutex_);
  arena = siteArenas_[siteId].load(std::memory_order_relaxed);
  if (arena) {
    if (!arena->matches(size, requestedAlignment)) {
      failure = SlabArenaFailure::Unsupported;
      return nullptr;
    }
    failure = SlabArenaFailure::None;
    return arena;
  }

  arena = new (std::nothrow) SiteArena(*this, siteId, size, requestedAlignment,
                                       effectiveAlignment, slotBytes);
  if (!arena) {
    failure = SlabArenaFailure::Unavailable;
    return nullptr;
  }

  siteArenas_[siteId].store(arena, std::memory_order_release);
  failure = SlabArenaFailure::None;
  return arena;
}

void *ArenaManager::allocate(uint64_t size, uint64_t align, uint32_t siteId,
                             SlabArenaFailure &failure) {
  SiteArena *arena = getOrCreateSiteArena(size, align, siteId, failure);
  if (!arena)
    return nullptr;
  return arena->allocate(failure);
}

Slab *ArenaManager::allocateSlab(SiteArena *owner, size_t capacity) {
  if (!owner || capacity == 0)
    return nullptr;

  size_t slabIndex = nextSlab_.load(std::memory_order_relaxed);
  while (true) {
    if (slabIndex >= slabCount_)
      return nullptr;
    if (nextSlab_.compare_exchange_weak(slabIndex, slabIndex + 1,
                                        std::memory_order_relaxed,
                                        std::memory_order_relaxed))
      break;
  }

  auto *slab = new (std::nothrow) Slab();
  if (!slab)
    return nullptr;

  slab->bitmapWords = (capacity + kBitsPerWord - 1) / kBitsPerWord;
  slab->allocated = new (std::nothrow) std::atomic<uint64_t>[slab->bitmapWords];
  if (!slab->allocated) {
    delete slab;
    return nullptr;
  }
  for (size_t i = 0; i < slab->bitmapWords; ++i)
    slab->allocated[i].store(0, std::memory_order_relaxed);

  slab->owner = owner;
  slab->base = region_ + slabIndex * slabBytes_;
  slab->capacity = capacity;
  slabOwners_[slabIndex].store(slab, std::memory_order_release);
  return slab;
}

SlabArenaDeallocation ArenaManager::deallocate(void *ptr) {
  uintptr_t address = reinterpret_cast<uintptr_t>(ptr);
  uintptr_t begin = reinterpret_cast<uintptr_t>(region_);
  uintptr_t end = begin + reserveBytes_;
  if (address < begin || address >= end)
    return SlabArenaDeallocation::NotOwned;

  size_t slabIndex = static_cast<size_t>((address - begin) / slabBytes_);
  Slab *slab = slabOwners_[slabIndex].load(std::memory_order_acquire);
  if (!slab || !slab->owner)
    return SlabArenaDeallocation::Invalid;

  return slab->owner->deallocate(ptr, *slab);
}

void ArenaManager::recordFallback(SlabArenaFailure failure) {
  switch (failure) {
  case SlabArenaFailure::Unavailable:
    fallbackUnavailable_.fetch_add(1, std::memory_order_relaxed);
    return;
  case SlabArenaFailure::Unsupported:
    fallbackUnsupported_.fetch_add(1, std::memory_order_relaxed);
    return;
  case SlabArenaFailure::Exhausted:
    fallbackExhausted_.fetch_add(1, std::memory_order_relaxed);
    return;
  case SlabArenaFailure::None:
    return;
  }
}

void ArenaManager::report() const {
  if (!reportEnabled_)
    return;

  uint64_t totalAllocations = 0;
  uint64_t totalFrees = 0;
  uint64_t totalLive = 0;
  uint64_t totalPeakLive = 0;
  uint64_t totalRequestedBytes = 0;
  uint64_t totalSlotBytes = 0;
  uint64_t totalSlabs = 0;

  for (size_t i = 0; i <= kMaxSiteId; ++i) {
    SiteArena *arena = siteArenas_[i].load(std::memory_order_acquire);
    if (!arena)
      continue;

    uint64_t allocations = arena->allocations();
    uint64_t frees = arena->frees();
    uint64_t live = arena->live();
    uint64_t peakLive = arena->peakLive();
    uint64_t requestedBytes = arena->requestedBytes();
    uint64_t slotBytes = arena->slotBytesTotal();
    uint64_t slabs = arena->assignedSlabs();
    totalAllocations += allocations;
    totalFrees += frees;
    totalLive += live;
    totalPeakLive += peakLive;
    totalRequestedBytes += requestedBytes;
    totalSlotBytes += slotBytes;
    totalSlabs += slabs;

    std::fprintf(stderr,
                 "arbiter-arena-site site=%u object_bytes=%" PRIu64
                 " requested_alignment=%" PRIu64 " effective_alignment=%" PRIu64
                 " slot_bytes=%" PRIu64 " allocations=%" PRIu64
                 " frees=%" PRIu64 " live=%" PRIu64 " peak_live=%" PRIu64
                 " requested_bytes_total=%" PRIu64 " slot_bytes_total=%" PRIu64
                 " assigned_slabs=%" PRIu64 " assigned_bytes=%" PRIu64 "\n",
                 arena->siteId(), arena->objectBytes(),
                 arena->requestedAlignment(), arena->effectiveAlignment(),
                 arena->slotBytes(), allocations, frees, live, peakLive,
                 requestedBytes, slotBytes, slabs, slabs * slabBytes_);
  }

  uint64_t fallbackUnavailable =
      fallbackUnavailable_.load(std::memory_order_relaxed);
  uint64_t fallbackUnsupported =
      fallbackUnsupported_.load(std::memory_order_relaxed);
  uint64_t fallbackExhausted =
      fallbackExhausted_.load(std::memory_order_relaxed);
  uint64_t fallbacks =
      fallbackUnavailable + fallbackUnsupported + fallbackExhausted;
  std::fprintf(stderr,
               "arbiter-arena-summary node=%d reserve_bytes=%" PRIu64
               " slab_bytes=%" PRIu64 " slot_alignment=%" PRIu64
               " assigned_slabs=%" PRIu64 " assigned_bytes=%" PRIu64
               " allocations=%" PRIu64 " frees=%" PRIu64 " live=%" PRIu64
               " peak_live=%" PRIu64 " requested_bytes_total=%" PRIu64
               " slot_bytes_total=%" PRIu64 " fallback_allocations=%" PRIu64
               " fallback_unavailable=%" PRIu64 " fallback_unsupported=%" PRIu64
               " fallback_exhausted=%" PRIu64 "\n",
               node_, reserveBytes_, slabBytes_, slotAlignment_, totalSlabs,
               totalSlabs * slabBytes_, totalAllocations, totalFrees, totalLive,
               totalPeakLive, totalRequestedBytes, totalSlotBytes, fallbacks,
               fallbackUnavailable, fallbackUnsupported, fallbackExhausted);

  reportResidency();
}

void ArenaManager::reportResidency() const {
#if !ARBITER_HAS_NUMA_ARENA
  return;
#else
  size_t pagesPerSlab = static_cast<size_t>(slabBytes_ / pageSize_);
  std::vector<unsigned char> resident(pagesPerSlab, 0);
  std::vector<void *> pages;
  std::vector<int> status;
  pages.reserve(pagesPerSlab);
  status.reserve(pagesPerSlab);

  int maxNode = numa_max_node();
  std::vector<uint64_t> nodePages(static_cast<size_t>(maxNode + 1), 0);
  uint64_t residentPages = 0;
  uint64_t queryErrorPages = 0;
  uint64_t mincoreErrorSlabs = 0;

  size_t assigned =
      std::min(nextSlab_.load(std::memory_order_acquire), slabCount_);
  for (size_t slabIndex = 0; slabIndex < assigned; ++slabIndex) {
    Slab *slab = slabOwners_[slabIndex].load(std::memory_order_acquire);
    if (!slab)
      continue;

    std::fill(resident.begin(), resident.end(), 0);
    if (mincore(slab->base, static_cast<size_t>(slabBytes_), resident.data()) !=
        0) {
      ++mincoreErrorSlabs;
      continue;
    }

    pages.clear();
    for (size_t page = 0; page < pagesPerSlab; ++page) {
      if ((resident[page] & 1) == 0)
        continue;
      pages.push_back(slab->base + page * pageSize_);
    }
    residentPages += pages.size();
    if (pages.empty())
      continue;

    status.assign(pages.size(), -1);
    if (move_pages(/*pid=*/0, pages.size(), pages.data(), /*nodes=*/nullptr,
                   status.data(), /*flags=*/0) != 0) {
      queryErrorPages += pages.size();
      continue;
    }

    for (int pageNode : status) {
      if (pageNode >= 0 && pageNode <= maxNode)
        ++nodePages[static_cast<size_t>(pageNode)];
      else
        ++queryErrorPages;
    }
  }

  int majorityNode = -1;
  uint64_t majorityPages = 0;
  for (int node = 0; node <= maxNode; ++node) {
    uint64_t count = nodePages[static_cast<size_t>(node)];
    if (count > majorityPages) {
      majorityPages = count;
      majorityNode = node;
    }
  }

  std::fprintf(stderr,
               "arbiter-arena-residency resident_pages=%" PRIu64
               " resident_bytes=%" PRIu64 " majority_node=%d"
               " query_error_pages=%" PRIu64 " mincore_error_slabs=%" PRIu64,
               residentPages, residentPages * pageSize_, majorityNode,
               queryErrorPages, mincoreErrorSlabs);
  for (int node = 0; node <= maxNode; ++node) {
    uint64_t count = nodePages[static_cast<size_t>(node)];
    if (count != 0)
      std::fprintf(stderr, " node%d_pages=%" PRIu64, node, count);
  }
  std::fputc('\n', stderr);
#endif
}

} // namespace

void *slabArenaAllocate(uint64_t size, uint64_t align, uint32_t siteId,
                        int32_t node, SlabArenaFailure &failure) {
  ArenaManager *manager = getOrCreateManager(node);
  if (!manager) {
    failure = SlabArenaFailure::Unavailable;
    return nullptr;
  }
  return manager->allocate(size, align, siteId, failure);
}

SlabArenaDeallocation slabArenaDeallocate(void *ptr) {
  ArenaManager *manager = managerSlot().load(std::memory_order_acquire);
  if (!manager)
    return SlabArenaDeallocation::NotOwned;
  return manager->deallocate(ptr);
}

void slabArenaRecordFallback(SlabArenaFailure failure) {
  ArenaManager *manager = managerSlot().load(std::memory_order_acquire);
  if (manager)
    manager->recordFallback(failure);
}

} // namespace arbiter::runtime
