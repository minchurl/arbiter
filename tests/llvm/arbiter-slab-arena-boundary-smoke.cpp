#include "arbiter_jemalloc_arena.h"
#include "arbiter_runtime_site.h"

#include <numaif.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <vector>

namespace {
bool failBind = false;
unsigned bindCalls = 0;

// Registered before the arena's atexit report: free after that report has run.
struct StaticCleanup {
  void *selected = nullptr;
  void *ordinary = nullptr;
  ~StaticCleanup() {
    arbiter_free_maybe(selected);
    arbiter_free_maybe(ordinary);
  }
} cleanup;
} // namespace

// Fault injection: strict placement must fail if the kernel rejects mbind.
extern "C" long mbind(void *addr, unsigned long bytes, int mode,
                      const unsigned long *mask, unsigned long maxnode,
                      unsigned flags) {
  ++bindCalls;
  if (failBind) {
    errno = EPERM;
    return -1;
  }
  return syscall(SYS_mbind, addr, bytes, mode, mask, maxnode, flags);
}

int main(int argc, char **argv) {
  const char *target = std::getenv("ARBITER_TARGET_NODE");
  constexpr int mapFlags = MAP_PRIVATE | MAP_ANONYMOUS;
  if (argc == 2 && std::strcmp(argv[1], "--invalid-config") == 0)
    return !arbiter_alloc_site(96, 64, 200, 0) &&
                   arbiter_mmap_site(4096, PROT_READ, mapFlags, 200, 0) ==
                       MAP_FAILED
               ? 0
               : 1;
  if (!target)
    return 2;
  int node = std::atoi(target);
  if (argc == 2 && std::strcmp(argv[1], "--fail-bind") == 0) {
    failBind = true;
    void *ptr = arbiter_alloc_site(96, 64, 200, 0);
    int heapError = errno;
    void *mapped = arbiter_mmap_site(4096, PROT_READ, mapFlags, 200, 0);
    return !ptr && mapped == MAP_FAILED && bindCalls && heapError == EPERM &&
                   errno == EPERM
               ? 0
               : 1;
  }
  if (argc != 1)
    return 2;

  // These obsolete settings cannot restrict allocation or reserve memory.
  setenv("ARBITER_ARENA_RESERVE_BYTES", "1", 1);
  setenv("ARBITER_ARENA_SLAB_BYTES", "1", 1);
  constexpr uint64_t sizes[] = {96, 128, 4 * 1024 * 1024 + 17, 4096};
  constexpr uint64_t aligns[] = {16, 64, 8192, 1024 * 1024};
  std::vector<void *> objects, pages;
  size_t pageSize = sysconf(_SC_PAGESIZE);
  for (unsigned i = 0; i < 4; ++i) {
    // One site accepts different sizes and alignments, including large objects.
    void *ptr = arbiter_alloc_site(sizes[i], aligns[i], 200, 0);
    if (!ptr || reinterpret_cast<uintptr_t>(ptr) % aligns[i])
      return 1;
    std::memset(ptr, 0x5a, sizes[i]);
    objects.push_back(ptr);
    uintptr_t start = reinterpret_cast<uintptr_t>(ptr) & ~(pageSize - 1);
    uintptr_t end = reinterpret_cast<uintptr_t>(ptr) + sizes[i];
    for (; start < end; start += pageSize)
      pages.push_back(reinterpret_cast<void *>(start));
  }
  std::vector<int> status(pages.size(), -1);
  if (move_pages(0, pages.size(), pages.data(), nullptr, status.data(), 0) != 0)
    return 1;
  for (int actual : status)
    if (actual != node)
      return 1;
  for (void *ptr : objects)
    arbiter_free_maybe(ptr);
  for (unsigned i = 0; i < 10000; ++i) {
    void *ptr = arbiter_alloc_site(96 + i % 7, 64, 200, 0);
    if (!ptr)
      return 1;
    arbiter_cxx_delete_maybe(ptr);
  }

  // An ordinary heap pointer and an unrelated mmap must never enter dallocx.
  using arbiter::runtime::arenaDeallocate;
  void *ordinary = std::malloc(128);
  void *mapping = mmap(nullptr, pageSize, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (!ordinary || mapping == MAP_FAILED || arenaDeallocate(ordinary) ||
      arenaDeallocate(mapping))
    return 1;
  arbiter_free_maybe(ordinary);
  munmap(mapping, pageSize);
  if (arbiter_alloc_site(96, 3, 200, 0) ||
      arbiter_alloc_site(std::numeric_limits<uint64_t>::max(), 64, 200, 0))
    return 1;
  // mmap keeps protection/partial-unmap semantics without a side table.
  // Test both demand faults and pages populated before mbind runs.
  for (int populate : {0, MAP_POPULATE}) {
    auto *mapped = static_cast<char *>(arbiter_mmap_site(
        2 * pageSize, PROT_READ, mapFlags | populate, 202, 0));
    if (mapped == MAP_FAILED ||
        mprotect(mapped, 2 * pageSize, PROT_READ | PROT_WRITE))
      return 1;
    std::memset(mapped, 0x5a, 2 * pageSize);
    void *mappedPages[] = {mapped, mapped + pageSize};
    int nodes[2];
    if (move_pages(0, 2, mappedPages, nullptr, nodes, 0) || nodes[0] != node ||
        nodes[1] != node || arbiter_munmap_maybe(mapped, pageSize) ||
        mapped[pageSize] != 0x5a ||
        arbiter_munmap_maybe(mapped + pageSize, pageSize))
      return 1;
  }
  if (arbiter_mmap_site(pageSize, PROT_READ, MAP_SHARED | MAP_ANONYMOUS, 202,
                        0) != MAP_FAILED)
    return 1;
  cleanup.selected = arbiter_alloc_site(96, 64, 201, 0);
  cleanup.ordinary = std::malloc(128);
  if (!cleanup.selected || !cleanup.ordinary)
    return 1;
  std::puts("arbiter-arena-boundary-smoke: dynamic sizes, alignment, "
            "placement, reuse and ownership passed");
  return 0;
}
