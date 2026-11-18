#include "arbiter_runtime_site.h"
#include "arbiter_jemalloc_arena.h"

#include <cerrno>
#include <cinttypes>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <new>
#include <sys/mman.h>

// libstdc++ hides the sized deallocation declarations unless the translation
// unit is compiled with -fsized-deallocation. The ABI symbols still exist and
// must be called exactly when the LLVM pass rewrites an existing call.
extern "C" void arbiter_abi_delete_sized(void *, size_t) noexcept
    __asm__("_ZdlPvm");
extern "C" void arbiter_abi_delete_sized_aligned(void *, size_t,
                                                 std::align_val_t) noexcept
    __asm__("_ZdlPvmSt11align_val_t");
extern "C" void arbiter_abi_delete_array_sized(void *, size_t) noexcept
    __asm__("_ZdaPvm");
extern "C" void
arbiter_abi_delete_array_sized_aligned(void *, size_t,
                                       std::align_val_t) noexcept
    __asm__("_ZdaPvmSt11align_val_t");

namespace {
void diagnose(const char *api, uint64_t size, uint64_t align, uint32_t site,
              arbiter::runtime::AllocationError error) {
  const char *node = std::getenv("ARBITER_TARGET_NODE");
  std::fprintf(stderr,
               "arbiter-allocation-failure api=%s site=%u bytes=%" PRIu64
               " alignment=%" PRIu64 " target_node=%s stage=%s errno=%d (%s)\n",
               api, site, size, align, node ? node : "unset", error.stage,
               error.code, std::strerror(error.code));
  errno = error.code;
}

void *allocate(const char *api, uint64_t size, uint64_t align, uint32_t site) {
  void *ptr = arbiter::runtime::arenaAllocate(size, align, site);
  if (!ptr)
    diagnose(api, size, align, site, arbiter::runtime::arenaError());
  return ptr;
}
} // namespace

extern "C" void *arbiter_alloc_site(uint64_t size, uint64_t align,
                                    uint32_t site_id, uint32_t reserved) {
  (void)reserved;
  return allocate("malloc", size, align, site_id);
}

extern "C" void *arbiter_new_site(uint64_t size, uint64_t align,
                                  uint32_t site_id, uint32_t reserved) {
  (void)reserved;
  for (;;) {
    if (void *ptr = allocate("new", size, align, site_id))
      return ptr;
    std::new_handler handler = std::get_new_handler();
    if (!handler)
      throw std::bad_alloc();
    handler(); // May release memory, throw, or terminate; retry the same arena.
  }
}

extern "C" void *arbiter_new_nothrow_site(uint64_t size, uint64_t align,
                                          uint32_t site_id, uint32_t reserved) {
  try {
    return arbiter_new_site(size, align, site_id, reserved);
  } catch (...) {
    return nullptr;
  }
}

extern "C" void *arbiter_calloc_site(uint64_t count, uint64_t elem_size,
                                     uint64_t align, uint32_t site_id,
                                     uint32_t reserved) {
  (void)reserved;
  if (elem_size && count > std::numeric_limits<size_t>::max() / elem_size) {
    diagnose("calloc", 0, align, site_id, {"size-overflow", ENOMEM});
    return nullptr;
  }
  uint64_t size = count * elem_size;
  void *ptr = allocate("calloc", size, align, site_id);
  if (ptr)
    std::memset(ptr, 0, static_cast<size_t>(size));
  return ptr;
}

extern "C" void *arbiter_mmap_site(uint64_t size, int prot, int mmap_flags,
                                   uint32_t site_id, uint32_t reserved) {
  (void)reserved;
  void *ptr = arbiter::runtime::arenaMap(size, prot, mmap_flags);
  if (ptr == MAP_FAILED)
    diagnose("mmap", size, 0, site_id, arbiter::runtime::arenaError());
  return ptr;
}

extern "C" void arbiter_free_maybe(void *ptr) {
  int saved = errno;
  if (ptr && !arbiter::runtime::arenaDeallocate(ptr))
    std::free(ptr);
  errno = saved;
}

extern "C" void arbiter_cxx_delete_maybe(void *ptr) {
  if (!ptr || arbiter::runtime::arenaDeallocate(ptr))
    return;
  ::operator delete(ptr);
}

extern "C" void arbiter_cxx_delete_sized_maybe(void *ptr, uint64_t size) {
  if (!ptr || arbiter::runtime::arenaDeallocate(ptr))
    return;
  arbiter_abi_delete_sized(ptr, static_cast<size_t>(size));
}

extern "C" void arbiter_cxx_delete_aligned_maybe(void *ptr, uint64_t align) {
  if (!ptr || arbiter::runtime::arenaDeallocate(ptr))
    return;
  ::operator delete(ptr, static_cast<std::align_val_t>(align));
}

extern "C" void arbiter_cxx_delete_sized_aligned_maybe(void *ptr, uint64_t size,
                                                       uint64_t align) {
  if (!ptr || arbiter::runtime::arenaDeallocate(ptr))
    return;
  arbiter_abi_delete_sized_aligned(ptr, static_cast<size_t>(size),
                                   static_cast<std::align_val_t>(align));
}

extern "C" void arbiter_cxx_delete_array_maybe(void *ptr) {
  if (!ptr || arbiter::runtime::arenaDeallocate(ptr))
    return;
  ::operator delete[](ptr);
}

extern "C" void arbiter_cxx_delete_array_sized_maybe(void *ptr, uint64_t size) {
  if (!ptr || arbiter::runtime::arenaDeallocate(ptr))
    return;
  arbiter_abi_delete_array_sized(ptr, static_cast<size_t>(size));
}

extern "C" void arbiter_cxx_delete_array_aligned_maybe(void *ptr,
                                                       uint64_t align) {
  if (!ptr || arbiter::runtime::arenaDeallocate(ptr))
    return;
  ::operator delete[](ptr, static_cast<std::align_val_t>(align));
}

extern "C" void arbiter_cxx_delete_array_sized_aligned_maybe(void *ptr,
                                                             uint64_t size,
                                                             uint64_t align) {
  if (!ptr || arbiter::runtime::arenaDeallocate(ptr))
    return;
  arbiter_abi_delete_array_sized_aligned(ptr, static_cast<size_t>(size),
                                         static_cast<std::align_val_t>(align));
}

extern "C" int arbiter_munmap_maybe(void *ptr, uint64_t size) {
  if (size > std::numeric_limits<size_t>::max()) {
    errno = EINVAL;
    return -1;
  }
  return munmap(ptr, static_cast<size_t>(size));
}
