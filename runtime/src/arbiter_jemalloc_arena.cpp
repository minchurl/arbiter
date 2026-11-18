#include "arbiter_jemalloc_arena.h"

#if ARBITER_HAS_NUMA_ARENA
#include <jemalloc/jemalloc.h>
#include <numa.h>
#include <numaif.h>
#include <sys/mman.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cinttypes>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

namespace arbiter::runtime {
namespace {

constexpr uint64_t kDefaultChunkBytes = 2ULL * 1024ULL * 1024ULL;
constexpr uint64_t kDefaultReserveBytes = 4ULL * 1024ULL * 1024ULL * 1024ULL;
constexpr uint64_t kDefaultSlotAlignment = 64;
constexpr uint32_t kMaxSiteId = 65535;
constexpr size_t kBitsPerWord = 64;

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

void updatePeak(std::atomic<uint64_t> &peak, uint64_t value) {
  uint64_t observed = peak.load(std::memory_order_relaxed);
  while (observed < value &&
         !peak.compare_exchange_weak(observed, value, std::memory_order_relaxed,
                                     std::memory_order_relaxed)) {
  }
}

struct SiteArena;

struct ArenaManager {
  static ArenaManager *create(int32_t node);
  void *allocate(uint64_t size, uint64_t align, uint32_t siteId,
                 ArenaFailure &failure);
  ArenaDeallocation deallocate(void *ptr);
  void recordFallback(ArenaFailure failure);
  void report() const;
  void reportResidency() const;

  // All extent hooks and address metadata live until process exit, including
  // during rewritten static destructors.
  unsigned char *region;
  size_t reserveBytes;
  size_t pageSize;
  size_t chunkBytes;
  size_t slotAlignment;
  int32_t node;
  bool reportEnabled;
  std::atomic<SiteArena *> sites[kMaxSiteId + 1]{};
  std::mutex siteMutex;
  std::mutex extentMutex;
  std::atomic<size_t> usedBytes{0};
  std::unique_ptr<uint16_t[]> pageOwner;
  std::unique_ptr<std::atomic<uint64_t>[]> liveStarts;
  std::atomic<uint64_t> fallbackUnavailable_{0};
  std::atomic<uint64_t> fallbackUnsupported_{0};
  std::atomic<uint64_t> fallbackExhausted_{0};
};

// jemalloc passes the same hooks pointer to every callback for this arena.
struct SiteArena : extent_hooks_t {
  ArenaManager &pool;
  uint32_t siteId;
  uint64_t objectBytes;
  uint64_t requestedAlignment;
  uint64_t effectiveAlignment;
  uint64_t slotBytes;
  int flags = 0;
  std::atomic<uint64_t> allocations{0}, live{0}, peakLive{0};
  std::atomic<uint64_t> assignedBytes{0}, assignedExtents{0};

  static void *allocateExtent(extent_hooks_t *hooks, void *newAddr, size_t size,
                              size_t alignment, bool *zero, bool *commit,
                              unsigned) {
    auto &site = *static_cast<SiteArena *>(hooks);
    auto &pool = site.pool;
    std::lock_guard<std::mutex> lock(pool.extentMutex);
    size_t used = pool.usedBytes.load(std::memory_order_relaxed);
    uintptr_t start = reinterpret_cast<uintptr_t>(pool.region + used);
    size_t padding = -start & (alignment - 1);
    size_t remaining = pool.reserveBytes - used;
    if (padding > remaining || size > remaining - padding)
      return nullptr;

    size_t offset = used + padding;
    void *addr = pool.region + offset;
    if (newAddr && newAddr != addr)
      return nullptr;

    std::fill_n(pool.pageOwner.get() + offset / pool.pageSize,
                size / pool.pageSize, site.siteId);
    pool.usedBytes.store(offset + size, std::memory_order_release);
    site.assignedBytes.fetch_add(size, std::memory_order_relaxed);
    site.assignedExtents.fetch_add(1, std::memory_order_relaxed);
    // This hook hands out each part of the anonymous mapping only once.
    *zero = true;
    *commit = true;
    return addr;
  }

  static bool splitExtent(extent_hooks_t *, void *, size_t, size_t, size_t,
                          bool, unsigned) {
    return false; // Both subranges retain the same NUMA policy and owner.
  }

  static bool mergeExtents(extent_hooks_t *, void *, size_t, void *, size_t,
                           bool, unsigned) {
    return false;
  }

  static bool purgeExtent(extent_hooks_t *, void *addr, size_t, size_t offset,
                          size_t length, unsigned) {
    return madvise(static_cast<unsigned char *>(addr) + offset, length,
                   MADV_DONTNEED) != 0;
  }

  SiteArena(ArenaManager &pool, uint32_t siteId, uint64_t size,
            uint64_t requestedAlignment, uint64_t effectiveAlignment)
      : extent_hooks_t{}, pool(pool), siteId(siteId), objectBytes(size),
        requestedAlignment(requestedAlignment),
        effectiveAlignment(effectiveAlignment),
        slotBytes(nallocx(size, MALLOCX_ALIGN(effectiveAlignment))) {
    alloc = allocateExtent;
    split = splitExtent;
    merge = mergeExtents;
    purge_forced = purgeExtent;
  }

  bool initialize() {
    extent_hooks_t *hooks = this;
    unsigned index;
    size_t len = sizeof(index);
    if (mallctl("arenas.create", &index, &len, &hooks, sizeof(hooks)) != 0)
      return false;

    // Bound speculative extent growth so a busy site cannot strand gigabytes
    // of the shared reserve in its arena. With retain disabled this control
    // is absent and jemalloc already requests extents on demand.
    char control[64];
    std::snprintf(control, sizeof(control), "arena.%u.retain_grow_limit",
                  index);
    size_t limit = pool.chunkBytes;
    int err = mallctl(control, nullptr, nullptr, &limit, sizeof(limit));
    if (err != 0 && err != ENOENT)
      std::fprintf(stderr, "arbiter-arena: %s: %s\n", control,
                   std::strerror(err));

    // A thread's default cache can contain objects from unrelated arenas.
    flags = MALLOCX_ARENA(index) | MALLOCX_TCACHE_NONE |
            MALLOCX_ALIGN(effectiveAlignment);
    return true;
  }
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

  uint64_t chunkBytes = 0;
  uint64_t reserveBytes = 0;
  uint64_t slotAlignment = 0;
  bool reportEnabled = false;
  if (!parsePositiveBytes("ARBITER_ARENA_SLAB_BYTES", kDefaultChunkBytes,
                          chunkBytes) ||
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
  if (chunkBytes < pageSize || chunkBytes % pageSize != 0) {
    std::fprintf(stderr,
                 "arbiter-arena: ARBITER_ARENA_SLAB_BYTES must be a positive "
                 "multiple of the page size (%" PRIu64 ")\n",
                 pageSize);
    return nullptr;
  }

  reserveBytes = (reserveBytes / chunkBytes) * chunkBytes;
  if (reserveBytes < chunkBytes ||
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

  std::unique_ptr<ArenaManager> manager(new (std::nothrow) ArenaManager{});
  if (manager) {
    manager->region = static_cast<unsigned char *>(mapping);
    manager->reserveBytes = reserveBytes;
    manager->chunkBytes = chunkBytes;
    manager->slotAlignment = slotAlignment;
    manager->pageSize = pageSize;
    manager->node = node;
    manager->reportEnabled = reportEnabled;
    manager->pageOwner.reset(new (std::nothrow)
                                 uint16_t[reserveBytes / pageSize]);
    size_t slots = reserveBytes / slotAlignment;
    manager->liveStarts.reset(
        new (std::nothrow)
            std::atomic<uint64_t>[(slots + kBitsPerWord - 1) / kBitsPerWord]());
    if (manager->pageOwner && manager->liveStarts)
      return manager.release();
  }

  munmap(mapping, reserveBytes);
  std::fprintf(stderr, "arbiter-arena: metadata allocation failed\n");
  return nullptr;
}

void *ArenaManager::allocate(uint64_t size, uint64_t align, uint32_t siteId,
                             ArenaFailure &failure) {
  failure = ArenaFailure::Unsupported;
  uint64_t requested = align == 0 ? alignof(std::max_align_t) : align;
  if (siteId > kMaxSiteId || size == 0 || !isPowerOfTwo(requested) ||
      requested > pageSize)
    return nullptr;

  SiteArena *site = sites[siteId].load(std::memory_order_acquire);
  if (!site) {
    size_t effective = std::max<size_t>(requested, slotAlignment);
    uint64_t rounded = 0;
    if (!checkedRoundUp(size, effective, rounded) || rounded > chunkBytes / 2)
      return nullptr;
    std::lock_guard<std::mutex> lock(siteMutex);
    site = sites[siteId].load(std::memory_order_relaxed);
    if (!site) {
      std::unique_ptr<SiteArena> fresh(new (std::nothrow) SiteArena(
          *this, siteId, size, requested, effective));
      if (!fresh || fresh->slotBytes == 0) {
        failure = ArenaFailure::Unavailable;
        return nullptr;
      }
      if (!fresh->initialize()) {
        failure = ArenaFailure::Exhausted;
        return nullptr;
      }
      site = fresh.release();
      sites[siteId].store(site, std::memory_order_release);
    }
  }
  if (size != site->objectBytes || requested != site->requestedAlignment)
    return nullptr;

  void *ptr = mallocx(size, site->flags);
  if (!ptr) {
    failure = ArenaFailure::Exhausted;
    return nullptr;
  }
  size_t slot = (static_cast<unsigned char *>(ptr) - region) / slotAlignment;
  uint64_t bit = uint64_t{1} << (slot % kBitsPerWord);
  liveStarts[slot / kBitsPerWord].fetch_or(bit, std::memory_order_release);
  site->allocations.fetch_add(1, std::memory_order_relaxed);
  updatePeak(site->peakLive,
             site->live.fetch_add(1, std::memory_order_relaxed) + 1);
  failure = ArenaFailure::None;
  return ptr;
}

ArenaDeallocation ArenaManager::deallocate(void *ptr) {
  uintptr_t offset =
      reinterpret_cast<uintptr_t>(ptr) - reinterpret_cast<uintptr_t>(region);
  if (offset >= reserveBytes)
    return ArenaDeallocation::NotOwned;
  if (offset % slotAlignment)
    return ArenaDeallocation::Invalid;

  // Resolving the extent alone cannot distinguish a live start from an
  // interior pointer or a second free. Only pass a verified start to dallocx.
  size_t slot = offset / slotAlignment;
  uint64_t bit = uint64_t{1} << (slot % kBitsPerWord);
  uint64_t previous = liveStarts[slot / kBitsPerWord].fetch_and(
      ~bit, std::memory_order_acq_rel);
  if ((previous & bit) == 0)
    return ArenaDeallocation::Invalid;
  auto *site =
      sites[pageOwner[offset / pageSize]].load(std::memory_order_acquire);
  site->live.fetch_sub(1, std::memory_order_relaxed);
  dallocx(ptr, MALLOCX_TCACHE_NONE);
  return ArenaDeallocation::Released;
}

void ArenaManager::recordFallback(ArenaFailure failure) {
  switch (failure) {
  case ArenaFailure::Unavailable:
    fallbackUnavailable_.fetch_add(1, std::memory_order_relaxed);
    return;
  case ArenaFailure::Unsupported:
    fallbackUnsupported_.fetch_add(1, std::memory_order_relaxed);
    return;
  case ArenaFailure::Exhausted:
    fallbackExhausted_.fetch_add(1, std::memory_order_relaxed);
    return;
  case ArenaFailure::None:
    return;
  }
}

void ArenaManager::report() const {
  if (!reportEnabled)
    return;

  uint64_t totalAllocations = 0;
  uint64_t totalFrees = 0;
  uint64_t totalLive = 0;
  uint64_t totalPeakLive = 0;
  uint64_t totalRequestedBytes = 0;
  uint64_t totalSlotBytes = 0;
  uint64_t totalAssignedBytes = 0;
  uint64_t totalExtents = 0;
  for (const auto &entry : sites) {
    SiteArena *site = entry.load(std::memory_order_acquire);
    if (!site)
      continue;
    uint64_t live = site->live.load();
    uint64_t allocations = site->allocations.load();
    uint64_t frees = allocations - live;
    uint64_t peakLive = site->peakLive.load();
    uint64_t requestedBytes = allocations * site->objectBytes;
    uint64_t slotBytes = allocations * site->slotBytes;
    uint64_t extents = site->assignedExtents.load();
    uint64_t assigned = site->assignedBytes.load();
    totalAssignedBytes += assigned;
    totalExtents += extents;
    totalAllocations += allocations;
    totalFrees += frees;
    totalLive += live;
    totalPeakLive += peakLive;
    totalRequestedBytes += requestedBytes;
    totalSlotBytes += slotBytes;

    std::fprintf(stderr,
                 "arbiter-arena-site site=%u object_bytes=%" PRIu64
                 " requested_alignment=%" PRIu64 " effective_alignment=%" PRIu64
                 " slot_bytes=%" PRIu64 " allocations=%" PRIu64
                 " frees=%" PRIu64 " live=%" PRIu64 " peak_live=%" PRIu64
                 " requested_bytes_total=%" PRIu64 " slot_bytes_total=%" PRIu64
                 " assigned_extents=%" PRIu64 " assigned_bytes=%" PRIu64 "\n",
                 site->siteId, site->objectBytes, site->requestedAlignment,
                 site->effectiveAlignment, site->slotBytes, allocations, frees,
                 live, peakLive, requestedBytes, slotBytes, extents, assigned);
  }

  uint64_t fallbackUnavailable =
      fallbackUnavailable_.load(std::memory_order_relaxed);
  uint64_t fallbackUnsupported =
      fallbackUnsupported_.load(std::memory_order_relaxed);
  uint64_t fallbackExhausted =
      fallbackExhausted_.load(std::memory_order_relaxed);
  uint64_t fallbacks =
      fallbackUnavailable + fallbackUnsupported + fallbackExhausted;
  std::fprintf(
      stderr,
      "arbiter-arena-summary node=%d allocator=jemalloc reserve_bytes=%zu"
      " slab_bytes=%zu slot_alignment=%zu"
      " assigned_extents=%" PRIu64 " assigned_bytes=%" PRIu64
      " allocations=%" PRIu64 " frees=%" PRIu64 " live=%" PRIu64
      " peak_live=%" PRIu64 " requested_bytes_total=%" PRIu64
      " slot_bytes_total=%" PRIu64 " fallback_allocations=%" PRIu64
      " fallback_unavailable=%" PRIu64 " fallback_unsupported=%" PRIu64
      " fallback_exhausted=%" PRIu64 "\n",
      node, reserveBytes, chunkBytes, slotAlignment, totalExtents,
      totalAssignedBytes, totalAllocations, totalFrees, totalLive,
      totalPeakLive, totalRequestedBytes, totalSlotBytes, fallbacks,
      fallbackUnavailable, fallbackUnsupported, fallbackExhausted);

  reportResidency();
}

void ArenaManager::reportResidency() const {
  constexpr size_t batchPages = 512;
  const size_t batchBytes = batchPages * pageSize;
  std::vector<unsigned char> resident(batchPages);
  std::vector<void *> pages;
  std::vector<int> status;
  pages.reserve(batchPages);
  status.reserve(batchPages);

  int maxNode = numa_max_node();
  std::vector<uint64_t> nodePages(static_cast<size_t>(maxNode + 1), 0);
  uint64_t residentPages = 0;
  uint64_t queryErrorPages = 0;
  uint64_t mincoreErrorBatches = 0;

  size_t used = usedBytes.load(std::memory_order_acquire);
  for (size_t offset = 0; offset < used;) {
    unsigned char *base = region + offset;
    size_t bytes = std::min(batchBytes, used - offset);
    offset += bytes;
    if (mincore(base, bytes, resident.data()) != 0) {
      ++mincoreErrorBatches;
      queryErrorPages += bytes / pageSize;
      continue;
    }
    pages.clear();
    for (size_t page = 0; page < bytes / pageSize; ++page) {
      if ((resident[page] & 1) == 0)
        continue;
      pages.push_back(base + page * pageSize);
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
               " query_error_pages=%" PRIu64 " mincore_error_batches=%" PRIu64,
               residentPages, residentPages * pageSize, majorityNode,
               queryErrorPages, mincoreErrorBatches);
  for (int node = 0; node <= maxNode; ++node) {
    uint64_t count = nodePages[static_cast<size_t>(node)];
    if (count != 0)
      std::fprintf(stderr, " node%d_pages=%" PRIu64, node, count);
  }
  std::fputc('\n', stderr);
}

} // namespace

void *arenaAllocate(uint64_t size, uint64_t align, uint32_t siteId,
                    int32_t node, ArenaFailure &failure) {
  ArenaManager *manager = getOrCreateManager(node);
  if (!manager) {
    failure = ArenaFailure::Unavailable;
    return nullptr;
  }
  return manager->allocate(size, align, siteId, failure);
}

ArenaDeallocation arenaDeallocate(void *ptr) {
  ArenaManager *manager = managerSlot().load(std::memory_order_acquire);
  if (!manager)
    return ArenaDeallocation::NotOwned;
  return manager->deallocate(ptr);
}

void arenaRecordFallback(ArenaFailure failure) {
  ArenaManager *manager = managerSlot().load(std::memory_order_acquire);
  if (manager)
    manager->recordFallback(failure);
}

} // namespace arbiter::runtime
#else

#include <cstdio>

namespace arbiter::runtime {
void *arenaAllocate(uint64_t, uint64_t, uint32_t, int32_t,
                    ArenaFailure &failure) {
  std::fprintf(stderr, "arbiter-arena: Linux NUMA arena support was not built\n");
  failure = ArenaFailure::Unavailable;
  return nullptr;
}
ArenaDeallocation arenaDeallocate(void *) {
  return ArenaDeallocation::NotOwned;
}
void arenaRecordFallback(ArenaFailure) {}
} // namespace arbiter::runtime
#endif
