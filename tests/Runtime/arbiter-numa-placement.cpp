#include "arbiter_runtime.h"

#include <numa.h>
#include <numaif.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <vector>

namespace {

constexpr uint64_t kDefaultSizeBytes = 256ULL * 1024ULL * 1024ULL;
constexpr uint64_t kDefaultAlignment = 4096;

bool parseUnsignedEnv(const char *name, uint64_t &value) {
  const char *raw = std::getenv(name);
  if (!raw || raw[0] == '\0')
    return true;

  errno = 0;
  char *end = nullptr;
  unsigned long long parsed = std::strtoull(raw, &end, 10);
  if (errno != 0 || end == raw || *end != '\0') {
    std::fprintf(stderr, "arbiter-numa-placement: invalid %s=%s\n", name, raw);
    return false;
  }

  value = static_cast<uint64_t>(parsed);
  return true;
}

bool parseIntEnv(const char *name, int &value, bool &present) {
  const char *raw = std::getenv(name);
  present = raw && raw[0] != '\0';
  if (!present)
    return true;

  errno = 0;
  char *end = nullptr;
  long parsed = std::strtol(raw, &end, 10);
  if (errno != 0 || end == raw || *end != '\0' || parsed < 0 ||
      parsed > std::numeric_limits<int>::max()) {
    std::fprintf(stderr, "arbiter-numa-placement: invalid %s=%s\n", name, raw);
    return false;
  }

  value = static_cast<int>(parsed);
  return true;
}

void touchPages(uint8_t *base, uint64_t sizeBytes, long pageSize) {
  for (uint64_t offset = 0; offset < sizeBytes;
       offset += static_cast<uint64_t>(pageSize))
    base[offset] = static_cast<uint8_t>(offset);
}

int findMajorityNode(const std::map<int, uint64_t> &counts) {
  int majorityNode = -1;
  uint64_t majorityCount = 0;
  for (const auto &entry : counts) {
    if (entry.second > majorityCount) {
      majorityNode = entry.first;
      majorityCount = entry.second;
    }
  }
  return majorityNode;
}

void printCounts(const std::map<int, uint64_t> &counts, uint64_t pageCount,
                 uint64_t sizeBytes, int majorityNode) {
  std::printf("arbiter_alloc:");
  for (const auto &entry : counts)
    std::printf(" node%d=%llu pages", entry.first,
                static_cast<unsigned long long>(entry.second));
  std::printf(" %.1f MiB majority=node%d\n",
              static_cast<double>(sizeBytes) / (1024.0 * 1024.0), majorityNode);

  uint64_t countedPages = 0;
  for (const auto &entry : counts)
    countedPages += entry.second;
  if (countedPages != pageCount)
    std::printf("arbiter_alloc: queried %llu/%llu pages\n",
                static_cast<unsigned long long>(countedPages),
                static_cast<unsigned long long>(pageCount));
}

} // namespace

int main() {
  if (numa_available() < 0) {
    std::fprintf(stderr, "arbiter-numa-placement: NUMA is unavailable\n");
    return 1;
  }

  long pageSize = ::sysconf(_SC_PAGESIZE);
  if (pageSize <= 0) {
    std::fprintf(stderr, "arbiter-numa-placement: failed to get page size\n");
    return 1;
  }

  uint64_t sizeBytes = kDefaultSizeBytes;
  if (!parseUnsignedEnv("ARBITER_PLACEMENT_BYTES", sizeBytes))
    return 1;

  uint64_t pageSizeU64 = static_cast<uint64_t>(pageSize);
  sizeBytes = (sizeBytes / pageSizeU64) * pageSizeU64;
  if (sizeBytes == 0) {
    std::fprintf(stderr,
                 "arbiter-numa-placement: ARBITER_PLACEMENT_BYTES is too "
                 "small\n");
    return 1;
  }

  bool hasExpectedNode = false;
  int expectedNode = -1;
  if (!parseIntEnv("ARBITER_EXPECT_NODE", expectedNode, hasExpectedNode))
    return 1;

  void *allocation = arbiter_alloc(sizeBytes, kDefaultAlignment);
  if (!allocation) {
    std::fprintf(stderr, "arbiter-numa-placement: allocation failed\n");
    return 1;
  }

  uint8_t *base = static_cast<uint8_t *>(allocation);
  touchPages(base, sizeBytes, pageSize);

  uint64_t pageCount = sizeBytes / pageSizeU64;
  std::vector<void *> pages;
  pages.reserve(pageCount);
  for (uint64_t i = 0; i < pageCount; ++i)
    pages.push_back(base + i * pageSizeU64);

  std::vector<int> status(pageCount, -1);
  if (move_pages(/*pid=*/0, pageCount, pages.data(), /*nodes=*/nullptr,
                 status.data(), /*flags=*/0) != 0) {
    std::fprintf(stderr, "arbiter-numa-placement: move_pages failed: %s\n",
                 std::strerror(errno));
    arbiter_dealloc(allocation);
    return 1;
  }

  std::map<int, uint64_t> counts;
  for (int node : status) {
    if (node >= 0)
      ++counts[node];
  }

  int majorityNode = findMajorityNode(counts);
  printCounts(counts, pageCount, sizeBytes, majorityNode);

  arbiter_dealloc(allocation);

  if (hasExpectedNode && majorityNode != expectedNode) {
    std::fprintf(stderr,
                 "arbiter-numa-placement: expected majority node%d, got "
                 "node%d\n",
                 expectedNode, majorityNode);
    return 1;
  }

  return 0;
}
