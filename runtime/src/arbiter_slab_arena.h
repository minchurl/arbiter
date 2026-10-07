#ifndef ARBITER_SLAB_ARENA_H
#define ARBITER_SLAB_ARENA_H

#include <cstdint>

namespace arbiter::runtime {

enum class SlabArenaFailure : uint8_t {
  None,
  Unavailable,
  Unsupported,
  Exhausted,
};

enum class SlabArenaDeallocation : uint8_t {
  NotOwned,
  Released,
  Invalid,
};

void *slabArenaAllocate(uint64_t size, uint64_t align, uint32_t siteId,
                        int32_t node, SlabArenaFailure &failure);
SlabArenaDeallocation slabArenaDeallocate(void *ptr);
void slabArenaRecordFallback(SlabArenaFailure failure);

} // namespace arbiter::runtime

#endif // ARBITER_SLAB_ARENA_H
