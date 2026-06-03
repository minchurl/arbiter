#include "arbiter_runtime.h"
#include "arbiter_runtime_site.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

bool isAligned(void *ptr, uint64_t alignment) {
  if (alignment == 0)
    alignment = sizeof(void *);
  return reinterpret_cast<uintptr_t>(ptr) % alignment == 0;
}

bool exerciseAllocation(uint64_t size, uint64_t alignment) {
  void *ptr = arbiter_alloc(size, alignment);
  if (!ptr) {
    std::fprintf(stderr,
                 "arbiter-runtime-smoke: allocation failed "
                 "(size=%llu, alignment=%llu)\n",
                 static_cast<unsigned long long>(size),
                 static_cast<unsigned long long>(alignment));
    return false;
  }

  if (!isAligned(ptr, alignment)) {
    std::fprintf(stderr,
                 "arbiter-runtime-smoke: misaligned pointer "
                 "(ptr=%p, alignment=%llu)\n",
                 ptr, static_cast<unsigned long long>(alignment));
    arbiter_dealloc(ptr);
    return false;
  }

  arbiter_dealloc(ptr);
  return true;
}

bool exerciseSiteAllocation(uint64_t size, uint64_t alignment) {
  void *ptr = arbiter_alloc_site(size, alignment, 1, 0);
  if (!ptr) {
    if (size == 0)
      return true;
    std::fprintf(stderr,
                 "arbiter-runtime-smoke: site allocation failed "
                 "(size=%llu, alignment=%llu)\n",
                 static_cast<unsigned long long>(size),
                 static_cast<unsigned long long>(alignment));
    return false;
  }

  if (size > 0)
    std::memset(ptr, 0x5a, static_cast<size_t>(size));
  arbiter_free_maybe(ptr);
  return true;
}

bool exerciseSiteCalloc() {
  constexpr uint64_t count = 8;
  constexpr uint64_t elemSize = 16;
  void *ptr = arbiter_calloc_site(count, elemSize, 64, 2, 0);
  if (!ptr) {
    std::fprintf(stderr, "arbiter-runtime-smoke: site calloc failed\n");
    return false;
  }

  auto *bytes = static_cast<unsigned char *>(ptr);
  for (uint64_t i = 0; i < count * elemSize; ++i) {
    if (bytes[i] != 0) {
      std::fprintf(stderr, "arbiter-runtime-smoke: site calloc not zeroed\n");
      arbiter_free_maybe(ptr);
      return false;
    }
  }

  arbiter_free_maybe(ptr);
  return true;
}

bool exerciseFreeFallback() {
  void *ptr = std::malloc(32);
  if (!ptr) {
    std::fprintf(stderr, "arbiter-runtime-smoke: malloc fallback setup failed\n");
    return false;
  }
  arbiter_free_maybe(ptr);
  return true;
}

} // namespace

int main() {
  constexpr uint64_t sizes[] = {0, 1, 37, 4096};
  constexpr uint64_t alignments[] = {1, 8, 16, 64, 4096};

  for (uint64_t size : sizes)
    for (uint64_t alignment : alignments)
      if (!exerciseAllocation(size, alignment))
        return 1;

  for (uint64_t size : sizes)
    for (uint64_t alignment : alignments)
      if (!exerciseSiteAllocation(size, alignment))
        return 1;

  if (!exerciseSiteCalloc() || !exerciseFreeFallback())
    return 1;

  return 0;
}
