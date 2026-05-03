#include "arbiter_runtime.h"

#include <cstdint>
#include <cstdio>

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

} // namespace

int main() {
  constexpr uint64_t sizes[] = {0, 1, 37, 4096};
  constexpr uint64_t alignments[] = {1, 8, 16, 64, 4096};

  for (uint64_t size : sizes)
    for (uint64_t alignment : alignments)
      if (!exerciseAllocation(size, alignment))
        return 1;

  return 0;
}
