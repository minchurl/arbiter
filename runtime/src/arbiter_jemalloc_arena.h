#ifndef ARBITER_JEMALLOC_ARENA_H
#define ARBITER_JEMALLOC_ARENA_H

#include <cstdint>

namespace arbiter::runtime {

enum class ArenaFailure : uint8_t {
  None,
  Unavailable,
  Unsupported,
  Exhausted,
};

enum class ArenaDeallocation : uint8_t {
  NotOwned,
  Released,
  Invalid,
};

void *arenaAllocate(uint64_t size, uint64_t align, uint32_t siteId,
                    int32_t node, ArenaFailure &failure);
ArenaDeallocation arenaDeallocate(void *ptr);
void arenaRecordFallback(ArenaFailure failure);

} // namespace arbiter::runtime

#endif // ARBITER_JEMALLOC_ARENA_H
