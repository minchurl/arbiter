#include "arbiter_runtime_site.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

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
  if (alignment > 1 &&
      reinterpret_cast<uintptr_t>(ptr) % alignment != 0) {
    std::fprintf(stderr,
                 "arbiter-runtime-smoke: pointer is not aligned "
                 "(ptr=%p, alignment=%llu)\n",
                 ptr, static_cast<unsigned long long>(alignment));
    arbiter_free_maybe(ptr);
    return false;
  }
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

bool exerciseDeleteFallbacks() {
  constexpr size_t size = 256;
  constexpr size_t alignment = 64;

  arbiter_cxx_delete_maybe(::operator new(size));
  arbiter_cxx_delete_sized_maybe(::operator new(size), size);
  arbiter_cxx_delete_aligned_maybe(
      ::operator new(size, static_cast<std::align_val_t>(alignment)),
      alignment);
  arbiter_cxx_delete_sized_aligned_maybe(
      ::operator new(size, static_cast<std::align_val_t>(alignment)), size,
      alignment);

  arbiter_cxx_delete_array_maybe(::operator new[](size));
  arbiter_cxx_delete_array_sized_maybe(::operator new[](size), size);
  arbiter_cxx_delete_array_aligned_maybe(
      ::operator new[](size, static_cast<std::align_val_t>(alignment)),
      alignment);
  arbiter_cxx_delete_array_sized_aligned_maybe(
      ::operator new[](size, static_cast<std::align_val_t>(alignment)), size,
      alignment);
  return true;
}

bool exerciseTrackedDeleteHelpers() {
  constexpr uint64_t size = 256;
  constexpr uint64_t alignment = 64;
  using DeleteFn = void (*)(void *);

  DeleteFn ordinary[] = {arbiter_cxx_delete_maybe,
                         arbiter_cxx_delete_array_maybe};
  for (DeleteFn fn : ordinary) {
    void *ptr = arbiter_alloc_site(size, alignment, 9, 0);
    if (!ptr)
      return false;
    fn(ptr);
  }

  void *ptr = arbiter_alloc_site(size, alignment, 10, 0);
  if (!ptr)
    return false;
  arbiter_cxx_delete_sized_maybe(ptr, size);
  ptr = arbiter_alloc_site(size, alignment, 11, 0);
  if (!ptr)
    return false;
  arbiter_cxx_delete_aligned_maybe(ptr, alignment);
  ptr = arbiter_alloc_site(size, alignment, 12, 0);
  if (!ptr)
    return false;
  arbiter_cxx_delete_sized_aligned_maybe(ptr, size, alignment);
  ptr = arbiter_alloc_site(size, alignment, 13, 0);
  if (!ptr)
    return false;
  arbiter_cxx_delete_array_sized_maybe(ptr, size);
  ptr = arbiter_alloc_site(size, alignment, 14, 0);
  if (!ptr)
    return false;
  arbiter_cxx_delete_array_aligned_maybe(ptr, alignment);
  ptr = arbiter_alloc_site(size, alignment, 15, 0);
  if (!ptr)
    return false;
  arbiter_cxx_delete_array_sized_aligned_maybe(ptr, size, alignment);
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

  if (!exerciseSiteCalloc() || !exerciseFreeFallback() ||
      !exerciseDeleteFallbacks() || !exerciseTrackedDeleteHelpers())
    return 1;

  return 0;
}
