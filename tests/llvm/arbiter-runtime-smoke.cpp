#include "arbiter_lock_touch_runtime.h"
#include "arbiter_runtime_site.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

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

bool exerciseLockTouch() {
  uint64_t lockLikeWord = 0;
  for (uint32_t i = 0; i < 2048; ++i)
    arbiter_lock_touch(&lockLikeWord, 99);
  return true;
}

} // namespace

int main() {
  constexpr uint64_t sizes[] = {0, 1, 37, 4096};
  constexpr uint64_t alignments[] = {1, 8, 16, 64, 4096};

  for (uint64_t size : sizes)
    for (uint64_t alignment : alignments)
      if (!exerciseSiteAllocation(size, alignment))
        return 1;

  if (!exerciseSiteCalloc() || !exerciseFreeFallback() || !exerciseLockTouch())
    return 1;

  return 0;
}
