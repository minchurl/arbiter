#include "arbiter_lock_page_table.h"

#include <array>
#include <cstddef>
#include <mutex>
#include <unordered_map>

namespace arbiter::runtime {
namespace {

constexpr size_t kShardCount = 256;

struct LockPageEntry {
  uint64_t sampledTouches = 0;
  bool migrationAttempted = false;
  bool migrated = false;
  uint32_t firstSiteId = 0;
};

struct LockPageShard {
  std::mutex mutex;
  std::unordered_map<void *, LockPageEntry> entries;
};

std::array<LockPageShard, kShardCount> &getShards() {
  static auto *shards = new std::array<LockPageShard, kShardCount>();
  return *shards;
}

LockPageShard &getShard(void *page) {
  uintptr_t value = reinterpret_cast<uintptr_t>(page);
  return getShards()[(value >> 12) % kShardCount];
}

} // namespace

bool lockPageRecordSample(void *page, uint32_t siteId, uint64_t threshold,
                          bool migrationEnabled) {
  if (!page)
    return false;

  LockPageShard &shard = getShard(page);
  std::lock_guard<std::mutex> lock(shard.mutex);

  LockPageEntry &entry = shard.entries[page];
  if (entry.firstSiteId == 0)
    entry.firstSiteId = siteId;

  ++entry.sampledTouches;
  if (!migrationEnabled || entry.migrationAttempted ||
      entry.sampledTouches < threshold)
    return false;

  entry.migrationAttempted = true;
  return true;
}

void lockPageMarkMigrated(void *page) {
  if (!page)
    return;

  LockPageShard &shard = getShard(page);
  std::lock_guard<std::mutex> lock(shard.mutex);
  auto it = shard.entries.find(page);
  if (it != shard.entries.end())
    it->second.migrated = true;
}

LockPageStats lockPageSnapshotStats() {
  LockPageStats stats{};

  for (LockPageShard &shard : getShards()) {
    std::lock_guard<std::mutex> lock(shard.mutex);
    stats.pages += shard.entries.size();

    for (const auto &entry : shard.entries) {
      const LockPageEntry &page = entry.second;
      stats.sampledTouches += page.sampledTouches;
      if (page.migrationAttempted)
        ++stats.migrationAttempts;
      if (page.migrated)
        ++stats.migrationSuccesses;
      if (page.sampledTouches > stats.maxSampledTouches)
        stats.maxSampledTouches = page.sampledTouches;
    }
  }

  return stats;
}

} // namespace arbiter::runtime
