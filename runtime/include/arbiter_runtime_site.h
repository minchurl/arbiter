#ifndef ARBITER_RUNTIME_SITE_H
#define ARBITER_RUNTIME_SITE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opt-in heap placement plan, configured before this site's first allocation.
// mmap placement is unchanged. Repeated/late configuration returns EBUSY.
// target_percent is 0 (local), 50 (interleave), or 100 (target first).
// max_target_bytes caps page-rounded backing mappings, including allocator
// metadata, for this site over its lifetime. UINT64_MAX means unlimited.
// Exhausting the cap deliberately places further backing in local_node;
// allocation/binding errors still fail strictly. Returns -1 with errno on error.
// If local_node equals ARBITER_TARGET_NODE, placement stays on that node and
// consumes no target budget. Plans do not migrate existing pages or adapt online.
int arbiter_set_site_placement(uint32_t site_id, int local_node,
                               unsigned target_percent,
                               uint64_t max_target_bytes);

// Snapshot this site's retained backing ranges. The visitor runs outside the
// registry lock; mappings survive until process exit, but pages may be purged
// or reused concurrently. Includes allocator metadata and unused capacity.
// Intended for diagnostics/experimental migration, not live-object enumeration.
int arbiter_visit_site_extents(uint32_t site_id,
    void (*visitor)(void *address, uint64_t bytes, void *context), void *context);

void *arbiter_alloc_site(uint64_t size, uint64_t align, uint32_t site_id,
                         uint32_t reserved);
void *arbiter_new_site(uint64_t size, uint64_t align, uint32_t site_id,
                       uint32_t reserved);
void *arbiter_new_nothrow_site(uint64_t size, uint64_t align, uint32_t site_id,
                               uint32_t reserved);
void *arbiter_calloc_site(uint64_t count, uint64_t elem_size, uint64_t align,
                          uint32_t site_id, uint32_t reserved);
void *arbiter_mmap_site(uint64_t size, int prot, int mmap_flags,
                        uint32_t site_id, uint32_t reserved);
void arbiter_free_maybe(void *ptr);
void arbiter_cxx_delete_maybe(void *ptr);
void arbiter_cxx_delete_sized_maybe(void *ptr, uint64_t size);
void arbiter_cxx_delete_aligned_maybe(void *ptr, uint64_t align);
void arbiter_cxx_delete_sized_aligned_maybe(void *ptr, uint64_t size,
                                            uint64_t align);
void arbiter_cxx_delete_array_maybe(void *ptr);
void arbiter_cxx_delete_array_sized_maybe(void *ptr, uint64_t size);
void arbiter_cxx_delete_array_aligned_maybe(void *ptr, uint64_t align);
void arbiter_cxx_delete_array_sized_aligned_maybe(void *ptr, uint64_t size,
                                                  uint64_t align);
int arbiter_munmap_maybe(void *ptr, uint64_t size);

#ifdef __cplusplus
}
#endif

#endif // ARBITER_RUNTIME_SITE_H
