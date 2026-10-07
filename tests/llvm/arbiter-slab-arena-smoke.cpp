#include "arbiter_runtime_site.h"

#include <numa.h>
#include <numaif.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <new>
#include <thread>
#include <vector>

namespace {

constexpr uint64_t kObjectBytes = 96;
constexpr uint64_t kRequestedAlignment = 16;
constexpr uint64_t kExpectedArenaAlignment = 64;
constexpr uint32_t kSiteId = 99;
constexpr uint64_t kDefaultObjects = 20000;
constexpr uint64_t kDefaultThreads = 8;

bool parseUnsignedEnv(const char *name, uint64_t defaultValue,
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
    std::fprintf(stderr, "arbiter-slab-arena-smoke: invalid %s=%s\n", name,
                 raw);
    return false;
  }
  value = static_cast<uint64_t>(parsed);
  return true;
}

bool parseExpectedNode(int &node, bool &present) {
  const char *raw = std::getenv("ARBITER_EXPECT_NODE");
  present = raw && raw[0] != '\0';
  if (!present)
    return true;

  errno = 0;
  char *end = nullptr;
  long parsed = std::strtol(raw, &end, 10);
  if (errno != 0 || end == raw || *end != '\0' || parsed < 0 ||
      parsed > std::numeric_limits<int>::max()) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-smoke: invalid ARBITER_EXPECT_NODE=%s\n",
                 raw);
    return false;
  }
  node = static_cast<int>(parsed);
  return true;
}

int majorityNode(const std::map<int, uint64_t> &counts) {
  int result = -1;
  uint64_t maximum = 0;
  for (const auto &entry : counts) {
    if (entry.second > maximum) {
      result = entry.first;
      maximum = entry.second;
    }
  }
  return result;
}

} // namespace

int main() {
  if (numa_available() < 0) {
    std::fprintf(stderr, "arbiter-slab-arena-smoke: NUMA is unavailable\n");
    return 1;
  }

  long pageSizeRaw = ::sysconf(_SC_PAGESIZE);
  if (pageSizeRaw <= 0) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-smoke: failed to query page size\n");
    return 1;
  }
  uint64_t pageSize = static_cast<uint64_t>(pageSizeRaw);

  uint64_t objectCount = 0;
  if (!parseUnsignedEnv("ARBITER_TEST_OBJECTS", kDefaultObjects, objectCount))
    return 1;

  uint64_t threadCount = 0;
  if (!parseUnsignedEnv("ARBITER_TEST_THREADS", kDefaultThreads, threadCount))
    return 1;
  if (threadCount > objectCount)
    threadCount = objectCount;

  int expectedNode = -1;
  bool hasExpectedNode = false;
  if (!parseExpectedNode(expectedNode, hasExpectedNode))
    return 1;

  std::vector<std::vector<void *>> threadAllocations(
      static_cast<size_t>(threadCount));
  std::vector<std::thread> workers;
  workers.reserve(static_cast<size_t>(threadCount));
  std::atomic<bool> allocationFailed(false);

  for (uint64_t thread = 0; thread < threadCount; ++thread) {
    uint64_t begin = objectCount * thread / threadCount;
    uint64_t end = objectCount * (thread + 1) / threadCount;
    workers.emplace_back([&, thread, begin, end] {
      std::vector<void *> &allocations =
          threadAllocations[static_cast<size_t>(thread)];
      allocations.reserve(static_cast<size_t>(end - begin));
      for (uint64_t i = begin; i < end; ++i) {
        void *ptr = arbiter_alloc_site(kObjectBytes, kRequestedAlignment,
                                       kSiteId, /*reserved=*/0);
        if (!ptr ||
            reinterpret_cast<uintptr_t>(ptr) % kExpectedArenaAlignment != 0) {
          allocationFailed.store(true, std::memory_order_relaxed);
          return;
        }
        std::memset(ptr, 0x5a, kObjectBytes);
        allocations.push_back(ptr);
      }
    });
  }
  for (std::thread &worker : workers)
    worker.join();

  if (allocationFailed.load(std::memory_order_relaxed)) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-smoke: concurrent allocation failed or "
                 "returned a misaligned pointer\n");
    return 1;
  }

  std::vector<void *> residentPages;
  residentPages.reserve(static_cast<size_t>(objectCount));
  for (const std::vector<void *> &allocations : threadAllocations) {
    for (void *ptr : allocations) {
      uintptr_t page = reinterpret_cast<uintptr_t>(ptr) & ~(pageSize - 1);
      residentPages.push_back(reinterpret_cast<void *>(page));
    }
  }

  std::sort(residentPages.begin(), residentPages.end());
  residentPages.erase(std::unique(residentPages.begin(), residentPages.end()),
                      residentPages.end());
  if (objectCount >= 8 && residentPages.size() >= objectCount / 4) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-smoke: objects were not densely packed "
                 "(%zu pages for %zu objects)\n",
                 residentPages.size(), static_cast<size_t>(objectCount));
    return 1;
  }

  std::vector<int> status(residentPages.size(), -1);
  if (move_pages(/*pid=*/0, residentPages.size(), residentPages.data(),
                 /*nodes=*/nullptr, status.data(), /*flags=*/0) != 0) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-smoke: move_pages query failed: %s\n",
                 std::strerror(errno));
    return 1;
  }

  std::map<int, uint64_t> counts;
  for (int node : status) {
    if (node >= 0)
      ++counts[node];
  }
  int observedNode = majorityNode(counts);

  workers.clear();
  for (std::vector<void *> &allocations : threadAllocations) {
    auto *ownedAllocations = &allocations;
    workers.emplace_back([ownedAllocations] {
      for (void *ptr : *ownedAllocations)
        arbiter_cxx_delete_maybe(ptr);
    });
  }
  for (std::thread &worker : workers)
    worker.join();

  // Allocate the same population again. The current slab has only partial
  // fresh capacity, so this must also exercise slots returned by free().
  std::vector<void *> reused;
  reused.reserve(static_cast<size_t>(objectCount));
  for (uint64_t i = 0; i < objectCount; ++i) {
    void *ptr = arbiter_alloc_site(kObjectBytes, kRequestedAlignment, kSiteId,
                                   /*reserved=*/0);
    if (!ptr) {
      std::fprintf(stderr,
                   "arbiter-slab-arena-smoke: recycled allocation failed\n");
      return 1;
    }
    std::memset(ptr, 0xa5, kObjectBytes);
    reused.push_back(ptr);
  }
  for (void *ptr : reused)
    arbiter_cxx_delete_maybe(ptr);

  void *ordinary = ::operator new(128, std::nothrow);
  if (!ordinary) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-smoke: ordinary allocation failed\n");
    return 1;
  }
  arbiter_cxx_delete_maybe(ordinary);

  std::printf(
      "arbiter-slab-arena-smoke: objects=%zu threads=%zu resident_pages=%zu ",
      static_cast<size_t>(objectCount), static_cast<size_t>(threadCount),
      residentPages.size());
  for (const auto &entry : counts)
    std::printf("node%d=%llu ", entry.first,
                static_cast<unsigned long long>(entry.second));
  std::printf("majority=node%d\n", observedNode);

  if (hasExpectedNode && observedNode != expectedNode) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-smoke: expected node%d, observed node%d\n",
                 expectedNode, observedNode);
    return 1;
  }

  return 0;
}
