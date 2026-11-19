#include "arbiter_runtime_site.h"
#include <numaif.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

static bool rejectInterleave = false;
extern "C" long mbind(void *address, unsigned long bytes, int mode,
                      const unsigned long *mask, unsigned long maxnode,
                      unsigned flags) {
  if (rejectInterleave && mode == MPOL_INTERLEAVE) {
    errno = EPERM;
    return -1;
  }
  return syscall(SYS_mbind, address, bytes, mode, mask, maxnode, flags);
}

static void require(bool value, const char *message) {
  if (!value) { std::fprintf(stderr, "%s (errno=%d)\n", message, errno); std::abort(); }
}
static std::pair<size_t, size_t> pages(void *pointer, size_t bytes, int target) {
  const size_t page = sysconf(_SC_PAGESIZE);
  std::vector<void *> addresses;
  // Require page-aligned allocations below: no overlap between query sets.
  for (size_t offset = 0; offset < bytes; offset += page)
    addresses.push_back(static_cast<char *>(pointer) + offset);
  std::vector<int> status(addresses.size());
  require(move_pages(0, addresses.size(), addresses.data(), nullptr, status.data(), 0) == 0, "query pages");
  size_t local = 0, remote = 0;
  for (int node : status) {
    require(node == 0 || node == target, "unexpected page node");
    if (node == target) ++remote; else ++local;
  }
  return {local, remote};
}
int main() {
  const char *configured = std::getenv("ARBITER_TARGET_NODE");
  require(configured != nullptr, "set ARBITER_TARGET_NODE for this test");
  const int target = std::atoi(configured);
  require(target != 0, "test needs a distinct target node");
  const size_t mib = 1024 * 1024, page = sysconf(_SC_PAGESIZE);
  require(arbiter_set_site_placement(70000, 0, 50, mib) == -1 && errno == EINVAL, "invalid site");
  require(arbiter_set_site_placement(100, 0, 49, mib) == -1 && errno == EINVAL, "unsupported fraction");
  require(arbiter_set_site_placement(100, -1, 50, mib) == -1 && errno == EINVAL, "invalid node");
  for (unsigned mode : {0u, 50u, 100u}) {
    const unsigned id = 100 + mode;
    const uint64_t cap = 8 * mib;
    require(arbiter_set_site_placement(id, 0, mode, cap) == 0, "configure plan");
    require(arbiter_set_site_placement(id, 0, mode, cap) == -1 && errno == EBUSY,
            "duplicate plan rejected before allocation");
    std::vector<void *> blocks;
    size_t targetBytes = 0, localBytes = 0;
    for (int i = 0; i < 3; ++i) {
      void *p = arbiter_alloc_site(12 * mib, page, id, 0);
      require(p != nullptr, "planned allocation");
      std::memset(p, i + 1, 12 * mib);
      auto counts = pages(p, 12 * mib, target);
      targetBytes += counts.second * page;
      localBytes += counts.first * page;
      blocks.push_back(p);
    }
    require(targetBytes <= cap, "site exceeded CXL cap");
    require(localBytes > 0, "cap must leave local pages");
    require(mode ? targetBytes > 0 : targetBytes == 0, "fraction applied");
    require(arbiter_set_site_placement(id, 0, 0, 0) == -1 && errno == EBUSY, "late reconfiguration rejected");
    for (void *p : blocks) arbiter_free_maybe(p);
    std::printf("mode=%u target_payload_bytes=%zu cap=%llu OK\n", mode, targetBytes, static_cast<unsigned long long>(cap));
  }
  require(arbiter_set_site_placement(250, 0, 100, page - 1) == 0, "subpage cap");
  void *tinyCap = arbiter_alloc_site(mib, page, 250, 0);
  require(tinyCap != nullptr, "subpage allocation");
  std::memset(tinyCap, 1, mib);
  require(pages(tinyCap, mib, target).second == 0, "subpage cap cannot grant target pages");
  arbiter_free_maybe(tinyCap);
  require(arbiter_set_site_placement(300, 0, 50, 8 * mib) == 0, "concurrent plan");
  std::vector<void *> blocks(8);
  std::vector<std::thread> workers;
  for (size_t i = 0; i < blocks.size(); ++i)
    workers.emplace_back([&, i] {
      blocks[i] = arbiter_alloc_site(4 * mib, page, 300, 0);
      require(blocks[i] != nullptr, "concurrent allocation");
      std::memset(blocks[i], 1, 4 * mib);
    });
  for (auto &worker : workers) worker.join();
  size_t targetBytes = 0;
  for (void *p : blocks) targetBytes += pages(p, 4 * mib, target).second * page;
  require(targetBytes <= 8 * mib, "concurrent budget overshoot");
  for (void *p : blocks) arbiter_free_maybe(p);
  void *strict = arbiter_alloc_site(mib, page, 400, 0);
  require(strict != nullptr, "default allocation");
  std::memset(strict, 1, mib);
  require(pages(strict, mib, target).first == 0, "unconfigured site changed policy");
  arbiter_free_maybe(strict);
  require(arbiter_set_site_placement(500, 0, 50, 8 * mib) == 0, "failure test plan");
  rejectInterleave = true;
  require(arbiter_alloc_site(mib, page, 500, 0) == nullptr,
          "failed interleave must not silently use local backing");
  rejectInterleave = false;
  void *retry = arbiter_alloc_site(mib, page, 500, 0);
  require(retry != nullptr, "retry after binding failure");
  std::memset(retry, 1, mib);
  require(pages(retry, mib, target).second > 0, "failed mapping consumed budget");
  arbiter_free_maybe(retry);
  std::puts("PASS placement caps, concurrent allocations, late-policy rejection, strict binding failure, default placement");
}
