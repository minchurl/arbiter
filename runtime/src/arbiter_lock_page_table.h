#ifndef ARBITER_LOCK_PAGE_TABLE_H
#define ARBITER_LOCK_PAGE_TABLE_H

#include <cstdint>

namespace arbiter::runtime {

struct LockPageStats {
  uint64_t pages = 0;
  uint64_t sampledTouches = 0;
  uint64_t migrationAttempts = 0;
  uint64_t migrationSuccesses = 0;
  uint64_t maxSampledTouches = 0;
};

bool lockPageRecordSample(void *page, uint32_t siteId, uint64_t threshold,
                          bool migrationEnabled);
void lockPageMarkMigrated(void *page);
LockPageStats lockPageSnapshotStats();

} // namespace arbiter::runtime

#endif // ARBITER_LOCK_PAGE_TABLE_H
