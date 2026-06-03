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
  uintptr_t value = reinterpret_cast<uintptr_t>(ptr);
  return getShards()[(value >> 4) % kShardCount];
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
