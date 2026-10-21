#include "arbiter_runtime_site.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

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

} // namespace

int main() {
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

  arbiter_free_maybe(baseline);
  if (!ok)
    return 1;

  std::printf("arbiter-slab-arena-boundary-smoke: ok\n");
  return 0;
}
