#ifndef ARBITER_RUNTIME_SITE_H
#define ARBITER_RUNTIME_SITE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void *arbiter_alloc_site(uint64_t size, uint64_t align, uint32_t site_id,
                         uint32_t flags);
void *arbiter_calloc_site(uint64_t count, uint64_t elem_size, uint64_t align,
                          uint32_t site_id, uint32_t flags);
void *arbiter_mmap_site(uint64_t size, int prot, int mmap_flags,
                        uint32_t site_id, uint32_t flags);
void arbiter_free_maybe(void *ptr);
void arbiter_cxx_delete_maybe(void *ptr);
void arbiter_cxx_delete_array_maybe(void *ptr);
int arbiter_munmap_maybe(void *ptr, uint64_t size);

#ifdef __cplusplus
}
#endif

#endif // ARBITER_RUNTIME_SITE_H
