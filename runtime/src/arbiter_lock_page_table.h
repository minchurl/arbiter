#ifndef ARBITER_LOCK_PAGE_TABLE_H
#define ARBITER_LOCK_PAGE_TABLE_H

#include <cstdint>

namespace arbiter::runtime {

bool lockPageRecordSample(void *page, uint32_t siteId, uint64_t threshold,
                          bool migrationEnabled);
void lockPageMarkMigrated(void *page);

} // namespace arbiter::runtime

#endif // ARBITER_LOCK_PAGE_TABLE_H
