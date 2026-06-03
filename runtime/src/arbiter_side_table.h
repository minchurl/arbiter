#ifndef ARBITER_SIDE_TABLE_H
#define ARBITER_SIDE_TABLE_H

#include <cstdint>

namespace arbiter::runtime {

enum class SideTableKind : uint8_t {
  Heap,
  MMap,
};

enum class SideTableBackend : uint8_t {
  Malloc,
  MMap,
  Numa,
};

struct SideTableEntry {
  SideTableKind kind;
  SideTableBackend backend;
  uint64_t size;
  uint32_t siteId;
  uint32_t flags;
  int32_t node;
};

bool sideTableInsert(void *ptr, const SideTableEntry &entry);
bool sideTableTake(void *ptr, SideTableEntry &entry);

} // namespace arbiter::runtime

#endif // ARBITER_SIDE_TABLE_H
