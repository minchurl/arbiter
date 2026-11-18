#ifndef ARBITER_JEMALLOC_ARENA_H
#define ARBITER_JEMALLOC_ARENA_H

#include <cstdint>

namespace arbiter::runtime {

struct AllocationError {
  const char *stage;
  int code;
};
AllocationError arenaError();

void *arenaAllocate(uint64_t size, uint64_t align, uint32_t siteId);
// Returns false for ordinary pointers, whose original free/delete must run.
bool arenaDeallocate(void *ptr);
void *arenaMap(uint64_t size, int prot, int flags);

} // namespace arbiter::runtime

#endif // ARBITER_JEMALLOC_ARENA_H
