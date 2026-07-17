#include "arbiter_lock_touch_runtime.h"

#include <numa.h>
#include <numaif.h>
#include <sys/mman.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>

namespace {

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
    std::fprintf(stderr, "arbiter-lock-touch-migration: invalid %s=%s\n", name,
                 raw);
    return false;
  }

  value = static_cast<int>(parsed);
  return true;
}

} // namespace

int main() {
  if (numa_available() < 0) {
    std::printf("arbiter-lock-touch-migration: NUMA unavailable, skipping\n");
    return 0;
  }

  bool hasTargetNode = false;
  int targetNode = -1;
  if (!parseIntEnv("ARBITER_TARGET_NODE", targetNode, hasTargetNode))
    return 1;
  if (!hasTargetNode) {
    std::printf(
        "arbiter-lock-touch-migration: ARBITER_TARGET_NODE unset, skipping\n");
    return 0;
  }

  bool hasExpectedNode = false;
  int expectedNode = -1;
  if (!parseIntEnv("ARBITER_EXPECT_NODE", expectedNode, hasExpectedNode))
    return 1;

  ::setenv("ARBITER_LOCK_TOUCH_MODE", "migrate", /*overwrite=*/1);
  ::setenv("ARBITER_LOCK_TOUCH_SAMPLE_PERIOD", "1", /*overwrite=*/1);
  ::setenv("ARBITER_LOCK_TOUCH_THRESHOLD", "1", /*overwrite=*/1);

  long pageSize = ::sysconf(_SC_PAGESIZE);
  if (pageSize <= 0) {
    std::fprintf(stderr,
                 "arbiter-lock-touch-migration: failed to get page size\n");
    return 1;
  }

  void *page = mmap(nullptr, static_cast<size_t>(pageSize),
                    PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (page == MAP_FAILED) {
    std::fprintf(stderr, "arbiter-lock-touch-migration: mmap failed: %s\n",
                 std::strerror(errno));
    return 1;
  }

  static_cast<unsigned char *>(page)[0] = 1;
  arbiter_lock_touch(page, 1);

  void *pages[] = {page};
  int status[] = {-1};
  if (move_pages(/*pid=*/0, /*count=*/1, pages, /*nodes=*/nullptr, status,
                 /*flags=*/0) != 0) {
    std::fprintf(stderr,
                 "arbiter-lock-touch-migration: move_pages query failed: %s\n",
                 std::strerror(errno));
    munmap(page, static_cast<size_t>(pageSize));
    return 1;
  }

  std::printf("arbiter-lock-touch-migration: page node%d target node%d\n",
              status[0], targetNode);
  munmap(page, static_cast<size_t>(pageSize));

  if (hasExpectedNode && status[0] != expectedNode) {
    std::fprintf(stderr,
                 "arbiter-lock-touch-migration: expected node%d, got node%d\n",
                 expectedNode, status[0]);
    return 1;
  }

  return 0;
}
