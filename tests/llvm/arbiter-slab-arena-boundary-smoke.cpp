#include "arbiter_jemalloc_arena.h"
#include "arbiter_runtime_site.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

uint64_t slabBytes() {
  constexpr uint64_t defaultSlabBytes = 2ULL * 1024ULL * 1024ULL;
  const char *raw = std::getenv("ARBITER_ARENA_SLAB_BYTES");
  if (!raw || raw[0] == '\0')
    return defaultSlabBytes;

  char *end = nullptr;
  unsigned long long parsed = std::strtoull(raw, &end, 10);
  if (end == raw || *end != '\0' || parsed == 0)
    return 0;
  return static_cast<uint64_t>(parsed);
}

bool requireNull(void *ptr, const char *caseName) {
  if (!ptr)
    return true;
  std::fprintf(stderr,
               "arbiter-slab-arena-boundary-smoke: %s unexpectedly "
               "succeeded\n",
               caseName);
  arbiter_free_maybe(ptr);
  return false;
}

// Run in a fresh process with a small cap. A misplaced ordinary-heap
// allocation would allow the payload alone to grow past that cap.
bool exerciseCapacity() {
  constexpr size_t reserve = 16 * 1024 * 1024;
  constexpr size_t object = 64 * 1024;
  if (setenv("ARBITER_ARENA_RESERVE_BYTES", "16777216", 1) != 0)
    return false;

  std::vector<void *> live;
  while (live.size() <= reserve / object) {
    void *ptr = arbiter_alloc_site(object, 64, 202, 0);
    if (!ptr)
      break;
    live.push_back(ptr);
  }
  if (live.empty() || live.size() > reserve / object) {
    std::fprintf(stderr, "unexpected capacity: %zu objects\n", live.size());
    return false;
  }
  // A saturated arena must be able to reuse space after a free.
  for (void *ptr : live)
    arbiter_free_maybe(ptr);
  for (auto &ptr : live) {
    ptr = arbiter_alloc_site(object, 64, 202, 0);
    if (!ptr)
      return false;
  }
  for (void *ptr : live)
    arbiter_free_maybe(ptr);
  return true;
}

} // namespace

int main(int argc, char **argv) {
  const char *backend = std::getenv("ARBITER_HEAP_BACKEND");
  const char *strict = std::getenv("ARBITER_ARENA_STRICT");
  if (!backend || std::strcmp(backend, "arena") != 0 || !strict ||
      std::strcmp(strict, "1") != 0 || !std::getenv("ARBITER_TARGET_NODE")) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-boundary-smoke: run with "
                 "ARBITER_HEAP_BACKEND=arena ARBITER_ARENA_STRICT=1 "
                 "ARBITER_TARGET_NODE=<node>\n");
    return 2;
  }

  if (argc == 2 && std::strcmp(argv[1], "--capacity") == 0)
    return exerciseCapacity() ? 0 : 1;

  void *baseline = arbiter_alloc_site(96, 16, 200, 0);
  if (!baseline) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-boundary-smoke: baseline allocation "
                 "failed\n");
    return 1;
  }

  bool ok = true;
  ok &= requireNull(arbiter_alloc_site(128, 16, 200, 0), "size mismatch");
  ok &= requireNull(arbiter_alloc_site(96, 64, 200, 0),
                    "alignment mismatch");

  const uint64_t slab = slabBytes();
  if (slab == 0) {
    std::fprintf(stderr,
                 "arbiter-slab-arena-boundary-smoke: invalid slab size\n");
    ok = false;
  } else {
    ok &= requireNull(arbiter_alloc_site(slab / 2 + 1, 16, 201, 0),
                      "oversized object");
  }

  // Exercise the ownership check used by every rewritten delete. A failed
  // check must leave the live object available for its legitimate owner.
  using arbiter::runtime::arenaDeallocate;
  using arbiter::runtime::ArenaDeallocation;
  auto *bytes = static_cast<unsigned char *>(baseline);
  if (arenaDeallocate(bytes + 1) != ArenaDeallocation::Invalid ||
      arenaDeallocate(bytes + 64) != ArenaDeallocation::Invalid)
    return 1;
  arbiter_free_maybe(baseline);
  if (arenaDeallocate(baseline) != ArenaDeallocation::Invalid)
    return 1;
  if (!ok)
    return 1;

  std::printf("arbiter-slab-arena-boundary-smoke: ok\n");
  return 0;
}
