#include "arbiter_runtime.h"

#include <cstdlib>

namespace {

uint64_t normalizeAlignment(uint64_t align) {
  constexpr uint64_t minAlign = sizeof(void *);
  if (align < minAlign)
    align = minAlign;

  // posix_memalign requires a power-of-two alignment.
  uint64_t normalized = minAlign;
  while (normalized < align)
    normalized <<= 1;
  return normalized;
}

} // namespace

extern "C" void *arbiter_alloc(uint64_t size, uint64_t align, int32_t policy) {
  (void)policy;

  void *ptr = nullptr;
  uint64_t normalizedAlign = normalizeAlignment(align);
  size_t requestSize = size == 0 ? 1 : static_cast<size_t>(size);

  if (posix_memalign(&ptr, static_cast<size_t>(normalizedAlign), requestSize) !=
      0)
    return nullptr;

  return ptr;
}

extern "C" void arbiter_dealloc(void *ptr, uint64_t size, int32_t policy) {
  (void)size;
  (void)policy;
  std::free(ptr);
}
