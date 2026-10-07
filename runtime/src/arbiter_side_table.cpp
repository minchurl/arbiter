#include "arbiter_side_table.h"

#include <array>
#include <cstddef>
#include <mutex>
#include <unordered_map>

namespace arbiter::runtime {
namespace {

constexpr size_t kShardCount = 256;

struct SideTableShard {
  std::mutex mutex;
  std::unordered_map<void *, SideTableEntry> entries;
};

std::array<SideTableShard, kShardCount> &getShards() {
  // Keep the table alive for C++ static destructors rewritten to delete helpers.
  static auto *shards = new std::array<SideTableShard, kShardCount>();
  return *shards;
}

SideTableShard &getShard(void *ptr) {
  // Mix high address bits as well as allocator-alignment bits. In particular,
  // numa_alloc_onnode returns page-aligned pointers, for which the old
  // `(value >> 4) % 256` expression mapped every entry to shard zero.
  uint64_t value = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(ptr));
  value ^= value >> 33;
  value *= UINT64_C(0xff51afd7ed558ccd);
  value ^= value >> 33;
  value *= UINT64_C(0xc4ceb9fe1a85ec53);
  value ^= value >> 33;
  return getShards()[value % kShardCount];
}

} // namespace

bool sideTableInsert(void *ptr, const SideTableEntry &entry) {
  if (!ptr)
    return false;

  SideTableShard &shard = getShard(ptr);
  std::lock_guard<std::mutex> lock(shard.mutex);
  return shard.entries.emplace(ptr, entry).second;
}

bool sideTableTake(void *ptr, SideTableEntry &entry) {
  if (!ptr)
    return false;

  SideTableShard &shard = getShard(ptr);
  std::lock_guard<std::mutex> lock(shard.mutex);
  auto it = shard.entries.find(ptr);
  if (it == shard.entries.end())
    return false;

  entry = it->second;
  shard.entries.erase(it);
  return true;
}

} // namespace arbiter::runtime
