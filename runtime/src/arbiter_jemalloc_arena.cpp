#include "arbiter_jemalloc_arena.h"

#include <cerrno>
#include <sys/mman.h>

#if ARBITER_HAS_NUMA_ARENA
#include <jemalloc/jemalloc.h>
#include <numa.h>
#include <numaif.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cinttypes>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <mutex>
#include <new>
#include <vector>

namespace arbiter::runtime {
namespace {
constexpr uint32_t kMaxSiteId = 65535;
thread_local AllocationError lastError{nullptr, 0};

void *fail(const char *stage, int code) {
  lastError = {stage, code};
  errno = code;
  return nullptr;
}

struct Placement {
  unsigned percent;
  uint64_t limit;
  int localNode;
  bitmask *local, *interleaved;
};
struct Arena;
struct Site : extent_hooks_t {
  Arena *owner;
  const Placement *placement = nullptr;
  std::atomic<uint64_t> targetAssigned{0};
  unsigned arena;
  uint64_t firstSize;
  std::atomic<bool> mixedSizes{false};
};
struct Extent {
  size_t size;
  unsigned arena;
};

// Only backing mappings are tracked here. jemalloc owns object allocation,
// free-space management and statistics. Mappings and hooks outlive static
// destructors; freed objects/extents are reused by jemalloc until process exit.
struct Arena : extent_hooks_t {
  int node;
  size_t pageSize, alignment;
  bitmask *mask;
  bool reportEnabled;
  std::atomic<Site *> sites[kMaxSiteId + 1]{};
  std::mutex siteMutex, extentMutex;
  std::mutex placementMutex;
  std::map<uint32_t, Placement> placements;
  std::map<uintptr_t, Extent> extents;

  static Arena *create();
  void report();
  void reportResidency(const std::map<uintptr_t, Extent> &ranges);

  bool bind(void *ptr, size_t size, unsigned flags = 0) {
    if (mbind(ptr, size, MPOL_BIND, mask->maskp, mask->size + 1, flags) == 0)
      return true;
    int error = errno;
    munmap(ptr, size);
    fail("mbind", error);
    return false;
  }

  bool bindPlanned(Site &site, void *ptr, size_t size, uint64_t &charged) {
    const Placement &plan = *site.placement;
    auto apply = [&](size_t bytes, int mode, bitmask *nodes) {
      if (!bytes || mbind(ptr, bytes, mode, nodes->maskp, nodes->size + 1, 0) == 0)
        return true;
      fail("mbind-placement-plan", errno);
      return false;
    };
    charged = 0;
    if (!apply(size, MPOL_BIND, plan.local))
      return false;
    if (!plan.percent || plan.localNode == node)
      return true;
    uint64_t used = site.targetAssigned.load(std::memory_order_relaxed);
    uint64_t available = (plan.limit - used) / pageSize;
    size_t pages = size / pageSize;
    size_t targetPages = std::min<uint64_t>(available, pages);
    if (!targetPages)
      return true;
    if (plan.percent == 50) {
      // An odd-length interleaved range may put its extra page on either
      // node. Charge the ceiling so the budget is always an upper bound.
      size_t spread = targetPages >= (pages + 1) / 2 ? pages : 2 * targetPages;
      charged = ((spread + 1) / 2) * pageSize;
      return apply(spread * pageSize, MPOL_INTERLEAVE, plan.interleaved);
    }
    charged = targetPages * pageSize;
    return apply(charged, MPOL_BIND, mask);
  }

  static void *mapExtent(extent_hooks_t *hooks, void *newAddr, size_t size,
                         size_t align, bool *zero, bool *commit,
                         unsigned index) {
    auto &site = *static_cast<Site *>(hooks);
    auto &arena = *site.owner;
    // Refuse fixed-address requests rather than overwriting an existing map.
    // jemalloc can retry with an unconstrained address.
    if (newAddr || size > std::numeric_limits<size_t>::max() - align)
      return nullptr;
    size_t bytes = size + (align > arena.pageSize ? align : 0);
    void *mapping = mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mapping == MAP_FAILED)
      return fail("extent-mmap", errno);
    uintptr_t base = reinterpret_cast<uintptr_t>(mapping);
    uintptr_t start = (base + align - 1) & ~(align - 1);
    size_t prefix = start - base, suffix = bytes - prefix - size;
    if (prefix)
      munmap(mapping, prefix);
    if (suffix)
      munmap(reinterpret_cast<void *>(start + size), suffix);
    void *ptr = reinterpret_cast<void *>(start);
    std::unique_lock<std::mutex> placementLock(arena.placementMutex,
                                              std::defer_lock);
    uint64_t charged = 0;
    if (site.placement) {
      placementLock.lock();
      if (!arena.bindPlanned(site, ptr, size, charged)) {
        int error = errno;
        munmap(ptr, size);
        errno = error;
        return nullptr;
      }
    } else if (!arena.bind(ptr, size)) {
      return nullptr;
    }
    try {
      std::lock_guard<std::mutex> lock(arena.extentMutex);
      arena.extents.emplace(start, Extent{size, index});
    } catch (const std::bad_alloc &) {
      munmap(ptr, size);
      return fail("extent-registry", ENOMEM);
    }
    site.targetAssigned.fetch_add(charged, std::memory_order_relaxed);
    *zero = *commit = true;
    return ptr;
  }

  static bool splitExtent(extent_hooks_t *, void *, size_t, size_t, size_t,
                          bool, unsigned) {
    return false;
  }
  static bool mergeExtents(extent_hooks_t *, void *, size_t, void *, size_t,
                           bool, unsigned) {
    return false;
  }
  static bool purgeExtent(extent_hooks_t *, void *addr, size_t, size_t offset,
                          size_t length, unsigned) {
    return madvise(static_cast<char *>(addr) + offset, length, MADV_DONTNEED) !=
           0;
  }
};

std::atomic<Arena *> activeArena{nullptr};

bool powerOfTwo(uint64_t n) { return n && !(n & (n - 1)); }

Arena *Arena::create() {
  const char *backend = std::getenv("ARBITER_HEAP_BACKEND");
  const char *strict = std::getenv("ARBITER_ARENA_STRICT");
  if ((backend && std::strcmp(backend, "arena")) ||
      (strict && std::strcmp(strict, "1"))) {
    fail("config-strict-arena", EINVAL);
    return nullptr;
  }
  const char *rawNode = std::getenv("ARBITER_TARGET_NODE");
  char *end;
  errno = 0;
  long node = rawNode ? std::strtol(rawNode, &end, 10) : -1;
  if (!rawNode || errno || end == rawNode || *end || node < 0 ||
      node > std::numeric_limits<int>::max()) {
    fail("config-target-node", EINVAL);
    return nullptr;
  }
  if (numa_available() < 0 || node > numa_max_node() ||
      !numa_bitmask_isbitset(numa_all_nodes_ptr, node)) {
    fail("numa-node", ENODEV);
    return nullptr;
  }
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) {
    fail("page-size", EINVAL);
    return nullptr;
  }
  size_t alignment = 64;
  if (const char *raw = std::getenv("ARBITER_ARENA_SLOT_ALIGNMENT")) {
    errno = 0;
    alignment = std::strtoull(raw, &end, 10);
    if (errno || end == raw || *end)
      alignment = 0;
  }
  if (!powerOfTwo(alignment) || alignment < alignof(std::max_align_t) ||
      alignment > static_cast<size_t>(page)) {
    fail("config-alignment", EINVAL);
    return nullptr;
  }
  const char *report = std::getenv("ARBITER_ARENA_REPORT");
  if (report && std::strcmp(report, "0") && std::strcmp(report, "1")) {
    fail("config-report", EINVAL);
    return nullptr;
  }
  auto *arena = new (std::nothrow) Arena{};
  if (!arena) {
    fail("arena-metadata", ENOMEM);
    return nullptr;
  }
  arena->mask = numa_allocate_nodemask();
  if (!arena->mask) {
    delete arena;
    fail("numa-mask", ENOMEM);
    return nullptr;
  }
  numa_bitmask_clearall(arena->mask);
  numa_bitmask_setbit(arena->mask, node);
  arena->node = node;
  arena->pageSize = page;
  arena->alignment = alignment;
  arena->reportEnabled = report && std::strcmp(report, "1") == 0;
  arena->alloc = mapExtent;
  arena->split = splitExtent;
  arena->merge = mergeExtents;
  arena->purge_forced = purgeExtent;
  if (std::getenv("ARBITER_ARENA_RESERVE_BYTES") ||
      std::getenv("ARBITER_ARENA_SLAB_BYTES"))
    std::fprintf(stderr,
                 "arbiter-arena: RESERVE_BYTES/SLAB_BYTES are obsolete; "
                 "extents grow on demand (use a process memory limit)\n");
  activeArena.store(arena, std::memory_order_release);
  std::atexit([] { activeArena.load()->report(); });
  return arena;
}

Arena *getArena() {
  struct Init {
    Arena *arena = Arena::create();
    AllocationError error = lastError;
  };
  static const Init init;
  if (!init.arena)
    lastError = init.error;
  return init.arena;
}

template <typename T> T stat(unsigned arena, const char *field) {
  char key[96];
  std::snprintf(key, sizeof(key), "stats.arenas.%u.%s", arena, field);
  T value;
  size_t bytes = sizeof(value);
  int err = mallctl(key, &value, &bytes, nullptr, 0);
  if (err) {
    std::fprintf(stderr, "arbiter-arena: cannot read %s: %s\n", key,
                 std::strerror(err));
    std::abort(); // A requested validation report must not silently omit data.
  }
  return value;
}

void Arena::report() {
  if (!reportEnabled)
    return;
  uint64_t epoch = 1;
  if (mallctl("epoch", nullptr, nullptr, &epoch, sizeof(epoch)) != 0)
    std::abort();
  std::map<uintptr_t, Extent> ranges;
  {
    std::lock_guard<std::mutex> lock(extentMutex);
    ranges = extents;
  }
  uint64_t allocations = 0, frees = 0, assigned = 0;
  for (uint32_t id = 0; id <= kMaxSiteId; ++id) {
    Site *site = sites[id].load(std::memory_order_acquire);
    if (!site)
      continue;
    unsigned index = site->arena;
    uint64_t a = stat<uint64_t>(index, "small.nmalloc") +
                 stat<uint64_t>(index, "large.nmalloc");
    uint64_t f = stat<uint64_t>(index, "small.ndalloc") +
                 stat<uint64_t>(index, "large.ndalloc");
    size_t liveBytes = stat<size_t>(index, "small.allocated") +
                       stat<size_t>(index, "large.allocated");
    uint64_t bytes = 0;
    for (const auto &range : ranges)
      if (range.second.arena == index)
        bytes += range.second.size;
    std::fprintf(stderr,
                 "arbiter-arena-site site=%u object_bytes=%" PRIu64
                 " allocations=%" PRIu64 " frees=%" PRIu64 " live=%" PRIu64
                 " allocated_bytes=%zu assigned_bytes=%" PRIu64 "\n",
                 id, site->mixedSizes.load() ? 0 : site->firstSize, a, f, a - f,
                 liveBytes, bytes);
    if (site->placement)
      std::fprintf(stderr,
                   "arbiter-placement-site site=%u local_node=%d target_node=%d"
                   " target_percent=%u target_limit_bytes=%" PRIu64
                   " target_assigned_bytes=%" PRIu64 "\n",
                   id, site->placement->localNode, node,
                   site->placement->percent, site->placement->limit,
                   site->targetAssigned.load(std::memory_order_relaxed));
    allocations += a;
    frees += f;
    assigned += bytes;
  }
  std::fprintf(
      stderr,
      "arbiter-arena-summary node=%d allocator=jemalloc backing=demand"
      " slot_alignment=%zu assigned_bytes=%" PRIu64 " allocations=%" PRIu64
      " frees=%" PRIu64 " live=%" PRIu64 " fallback_allocations=0\n",
      node, alignment, assigned, allocations, frees, allocations - frees);
  reportResidency(ranges);
}

void Arena::reportResidency(const std::map<uintptr_t, Extent> &ranges) {
  constexpr size_t batch = 512;
  unsigned char resident[batch];
  void *pages[batch];
  int status[batch];
  std::vector<uint64_t> counts(numa_max_node() + 1, 0);
  uint64_t total = 0, errors = 0, mincoreErrors = 0, zeroPages = 0;
  for (const auto &range : ranges) {
    for (size_t offset = 0; offset < range.second.size;
         offset += batch * pageSize) {
      auto *base = reinterpret_cast<unsigned char *>(range.first + offset);
      size_t bytes = std::min(batch * pageSize, range.second.size - offset);
      if (mincore(base, bytes, resident) != 0) {
        ++mincoreErrors;
        errors += bytes / pageSize;
        continue;
      }
      size_t n = 0;
      for (size_t i = 0; i < bytes / pageSize; ++i)
        if (resident[i] & 1)
          pages[n++] = base + i * pageSize;
      if (!n)
        continue;
      if (move_pages(0, n, pages, nullptr, status, 0) != 0) {
        errors += n;
        continue;
      }
      for (size_t i = 0; i < n; ++i)
        if (status[i] >= 0 && static_cast<size_t>(status[i]) < counts.size()) {
          ++counts[status[i]];
          ++total;
        } else if (status[i] == -EFAULT &&
                   mincore(pages[i], pageSize, resident) == 0) {
          // move_pages reports EFAULT for the kernel's shared zero page.
          // Check the mapping still exists; it has no private NUMA page yet.
          ++zeroPages;
        } else {
          ++errors;
        }
    }
  }
  int majority =
      total ? std::max_element(counts.begin(), counts.end()) - counts.begin()
            : -1;
  std::fprintf(stderr,
               "arbiter-arena-residency resident_pages=%" PRIu64
               " resident_bytes=%" PRIu64 " majority_node=%d"
               " query_error_pages=%" PRIu64 " mincore_error_batches=%" PRIu64
               " zero_pages=%" PRIu64,
               total, total * pageSize, majority, errors, mincoreErrors,
               zeroPages);
  for (size_t i = 0; i < counts.size(); ++i)
    if (counts[i])
      std::fprintf(stderr, " node%zu_pages=%" PRIu64, i, counts[i]);
  std::fputc('\n', stderr);
}
} // namespace

AllocationError arenaError() { return lastError; }

int visitSiteExtents(uint32_t id,
    void (*visitor)(void *, uint64_t, void *), void *context) {
  if (id > kMaxSiteId || !visitor) { errno = EINVAL; return -1; }
  Arena *arena = activeArena.load(std::memory_order_acquire);
  Site *site = arena ? arena->sites[id].load(std::memory_order_acquire) : nullptr;
  if (!site) { errno = ENOENT; return -1; }
  std::vector<std::pair<uintptr_t, size_t>> ranges;
  try {
    std::lock_guard<std::mutex> lock(arena->extentMutex);
    for (const auto &[address, extent] : arena->extents)
      if (extent.arena == site->arena)
        ranges.emplace_back(address, extent.size);
  } catch (const std::bad_alloc &) { errno = ENOMEM; return -1; }
  for (const auto &[address, bytes] : ranges)
    visitor(reinterpret_cast<void *>(address), bytes, context);
  return 0;
}

int setSitePlacement(uint32_t id, int localNode, unsigned percent,
                     uint64_t limit) {
  if (id > kMaxSiteId || (percent != 0 && percent != 50 && percent != 100) ||
      localNode < 0 || numa_available() < 0 || localNode > numa_max_node() ||
      !numa_bitmask_isbitset(numa_all_nodes_ptr, localNode)) {
    errno = EINVAL;
    return -1;
  }
  Arena *arena = getArena();
  if (!arena)
    return -1;
  std::lock_guard<std::mutex> lock(arena->siteMutex);
  if (arena->sites[id].load(std::memory_order_acquire) ||
      arena->placements.count(id)) {
    errno = EBUSY;
    return -1;
  }
  bitmask *local = numa_allocate_nodemask();
  bitmask *interleaved = numa_allocate_nodemask();
  if (!local || !interleaved) {
    if (local) numa_free_nodemask(local);
    if (interleaved) numa_free_nodemask(interleaved);
    errno = ENOMEM;
    return -1;
  }
  numa_bitmask_clearall(local);
  numa_bitmask_setbit(local, localNode);
  numa_bitmask_clearall(interleaved);
  numa_bitmask_setbit(interleaved, localNode);
  numa_bitmask_setbit(interleaved, arena->node);
  try {
    arena->placements.emplace(id, Placement{percent, limit, localNode,
                                            local, interleaved});
  } catch (const std::bad_alloc &) {
    numa_free_nodemask(local);
    numa_free_nodemask(interleaved);
    errno = ENOMEM;
    return -1;
  }
  return 0;
}

void *arenaAllocate(uint64_t size, uint64_t align, uint32_t siteId) {
  lastError = {nullptr, 0};
  if (size > static_cast<uint64_t>(std::numeric_limits<ptrdiff_t>::max()))
    return fail("size", ENOMEM);
  if (siteId > kMaxSiteId)
    return fail("site-id", EINVAL);
  if (align &&
      (!powerOfTwo(align) || align > std::numeric_limits<size_t>::max()))
    return fail("alignment", EINVAL);
  Arena *arena = getArena();
  if (!arena)
    return nullptr;
  Site *site = arena->sites[siteId].load(std::memory_order_acquire);
  if (!site) {
    std::lock_guard<std::mutex> lock(arena->siteMutex);
    site = arena->sites[siteId].load(std::memory_order_relaxed);
    if (!site) {
      site = new (std::nothrow) Site{};
      if (!site)
        return fail("site-metadata", ENOMEM);
      *static_cast<extent_hooks_t *>(site) = *arena;
      site->owner = arena;
      auto policy = arena->placements.find(siteId);
      if (policy != arena->placements.end())
        site->placement = &policy->second;
      extent_hooks_t *hooks = site;
      size_t len = sizeof(site->arena);
      int error =
          mallctl("arenas.create", &site->arena, &len, &hooks, sizeof(hooks));
      if (error) {
        delete site;
        return lastError.stage ? nullptr : fail("arenas.create", error);
      }
      site->firstSize = size;
      arena->sites[siteId].store(site, std::memory_order_release);
    }
  }
  if (size != site->firstSize)
    site->mixedSizes.store(true, std::memory_order_relaxed);
  int flags = MALLOCX_ARENA(site->arena) | MALLOCX_TCACHE_NONE |
              MALLOCX_ALIGN(std::max<uint64_t>(align, arena->alignment));
  // mallocx forbids zero; a zero-size C/C++ request still gets a freeable
  // pointer.
  void *ptr = mallocx(size ? size : 1, flags);
  if (!ptr && !lastError.stage)
    fail("mallocx", ENOMEM);
  return ptr;
}

bool arenaDeallocate(void *ptr) {
  Arena *arena = activeArena.load(std::memory_order_acquire);
  if (!arena)
    return false;
  {
    std::lock_guard<std::mutex> lock(arena->extentMutex);
    auto it = arena->extents.upper_bound(reinterpret_cast<uintptr_t>(ptr));
    if (it == arena->extents.begin())
      return false;
    --it;
    if (reinterpret_cast<uintptr_t>(ptr) - it->first >= it->second.size)
      return false;
  }
  // As with free(), ptr must be a live allocation start. We deliberately leave
  // invalid/double-free diagnostics to allocator debugging tools, not a bitmap.
  dallocx(ptr, MALLOCX_TCACHE_NONE);
  return true;
}

// Anonymous mmap stays a real mapping, so ordinary/partial munmap needs no
// ownership table. MOVE handles pages faulted early by MAP_POPULATE/LOCKED;
// STRICT rejects a mapping if those pages cannot reach the requested node.
void *arenaMap(uint64_t size, int prot, int flags) {
  lastError = {nullptr, 0};
  Arena *arena = getArena();
  if (!arena)
    return MAP_FAILED;
  // Only private anonymous mappings can use this per-range NUMA contract.
  if (!size || size > std::numeric_limits<size_t>::max() ||
      !(flags & MAP_ANONYMOUS) || (flags & MAP_TYPE) != MAP_PRIVATE ||
      (flags & (MAP_FIXED | MAP_FIXED_NOREPLACE))) {
    fail("mmap-arguments", EINVAL);
    return MAP_FAILED;
  }
  void *ptr = mmap(nullptr, size, prot, flags, -1, 0);
  if (ptr == MAP_FAILED) {
    fail("mmap", errno);
    return ptr;
  }
  return arena->bind(ptr, size, MPOL_MF_MOVE | MPOL_MF_STRICT) ? ptr
                                                               : MAP_FAILED;
}
} // namespace arbiter::runtime
#else
namespace arbiter::runtime {
AllocationError arenaError() { return {"numa-unavailable", ENOSYS}; }
void *arenaAllocate(uint64_t, uint64_t, uint32_t) { return nullptr; }
bool arenaDeallocate(void *) { return false; }
void *arenaMap(uint64_t, int, int) { return MAP_FAILED; }
} // namespace arbiter::runtime
#endif

extern "C" int arbiter_set_site_placement(uint32_t id, int local_node,
                                          unsigned percent, uint64_t limit) {
#if ARBITER_HAS_NUMA_ARENA
  return arbiter::runtime::setSitePlacement(id, local_node, percent, limit);
#else
  errno = ENOSYS;
  return -1;
#endif
}

extern "C" int arbiter_visit_site_extents(uint32_t id,
    void (*visitor)(void *, uint64_t, void *), void *context) {
#if ARBITER_HAS_NUMA_ARENA
  return arbiter::runtime::visitSiteExtents(id, visitor, context);
#else
  errno = ENOSYS;
  return -1;
#endif
}
