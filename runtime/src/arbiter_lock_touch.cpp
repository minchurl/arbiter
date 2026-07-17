#include "arbiter_lock_touch_runtime.h"

#include "arbiter_lock_page_table.h"

#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <unistd.h>

#if ARBITER_HAS_MOVE_PAGES
#include <numaif.h>
#endif

namespace {

using arbiter::runtime::lockPageMarkMigrated;
using arbiter::runtime::lockPageRecordSample;
using arbiter::runtime::lockPageSnapshotStats;
using arbiter::runtime::LockPageStats;

constexpr int32_t kNoTargetNode = -1;
constexpr uint64_t kDefaultSamplePeriod = 1024;
constexpr uint64_t kDefaultThreshold = 64;
constexpr uint64_t kFallbackPageSize = 4096;

enum class LockTouchMode : uint8_t {
  Off,
  Touch,
  Migrate,
};

struct LockTouchConfig {
  bool hasTargetNode;
  int32_t targetNode;
  LockTouchMode mode;
  bool statsEnabled;
  uint64_t samplePeriod;
  uint64_t sampleMask;
  bool useMask;
  uint64_t threshold;
};

std::atomic<uint64_t> gHookCalls{0};
std::atomic<uint64_t> gSampledCalls{0};

bool parseTargetNode(int32_t &node) {
  const char *value = std::getenv("ARBITER_TARGET_NODE");
  if (!value || value[0] == '\0')
    return false;

  errno = 0;
  char *end = nullptr;
  long long parsed = std::strtoll(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed < 0 ||
      parsed > std::numeric_limits<int32_t>::max())
    return false;

  node = static_cast<int32_t>(parsed);
  return true;
}

bool parseUnsignedEnv(const char *name, uint64_t &value) {
  const char *raw = std::getenv(name);
  if (!raw || raw[0] == '\0')
    return false;

  errno = 0;
  char *end = nullptr;
  unsigned long long parsed = std::strtoull(raw, &end, 10);
  if (errno != 0 || end == raw || *end != '\0' || parsed == 0)
    return false;

  value = static_cast<uint64_t>(parsed);
  return true;
}

bool parseBoolEnv(const char *name) {
  const char *raw = std::getenv(name);
  if (!raw || raw[0] == '\0')
    return false;

  return std::strcmp(raw, "0") != 0 && std::strcmp(raw, "false") != 0 &&
         std::strcmp(raw, "off") != 0;
}

bool isPowerOfTwo(uint64_t value) {
  return value != 0 && (value & (value - 1)) == 0;
}

bool hasMovePagesSupport() {
#if ARBITER_HAS_MOVE_PAGES
  return true;
#else
  return false;
#endif
}

LockTouchMode defaultMode(bool hasTargetNode) {
  return hasTargetNode && hasMovePagesSupport() ? LockTouchMode::Migrate
                                                : LockTouchMode::Touch;
}

LockTouchMode parseMode(bool hasTargetNode) {
  const char *value = std::getenv("ARBITER_LOCK_TOUCH_MODE");
  if (!value || value[0] == '\0' || std::strcmp(value, "auto") == 0)
    return defaultMode(hasTargetNode);

  if (std::strcmp(value, "off") == 0)
    return LockTouchMode::Off;
  if (std::strcmp(value, "touch") == 0)
    return LockTouchMode::Touch;
  if (std::strcmp(value, "migrate") == 0)
    return LockTouchMode::Migrate;

  return defaultMode(hasTargetNode);
}

const char *modeName(LockTouchMode mode) {
  switch (mode) {
  case LockTouchMode::Off:
    return "off";
  case LockTouchMode::Touch:
    return "touch";
  case LockTouchMode::Migrate:
    return "migrate";
  }
  return "unknown";
}

LockTouchConfig loadConfig() {
  LockTouchConfig config{false,
                         kNoTargetNode,
                         LockTouchMode::Touch,
                         false,
                         kDefaultSamplePeriod,
                         kDefaultSamplePeriod - 1,
                         true,
                         kDefaultThreshold};

  config.hasTargetNode = parseTargetNode(config.targetNode);
  config.mode = parseMode(config.hasTargetNode);
  config.statsEnabled = parseBoolEnv("ARBITER_LOCK_TOUCH_STATS");

  uint64_t samplePeriod = 0;
  if (parseUnsignedEnv("ARBITER_LOCK_TOUCH_SAMPLE_PERIOD", samplePeriod))
    config.samplePeriod = samplePeriod;
  config.useMask = isPowerOfTwo(config.samplePeriod);
  config.sampleMask = config.samplePeriod - 1;

  uint64_t threshold = 0;
  if (parseUnsignedEnv("ARBITER_LOCK_TOUCH_THRESHOLD", threshold))
    config.threshold = threshold;

  return config;
}

void printStatsAtExit();

const LockTouchConfig &getConfig() {
  static const LockTouchConfig config = [] {
    LockTouchConfig loaded = loadConfig();
    if (loaded.statsEnabled)
      std::atexit(printStatsAtExit);
    return loaded;
  }();
  return config;
}

void printStatsAtExit() {
  const LockTouchConfig &config = getConfig();
  LockPageStats pageStats = lockPageSnapshotStats();
  std::fprintf(stderr,
               "arbiter-lock-touch-stats: mode=%s target_node=%d "
               "has_target_node=%u sample_period=%llu threshold=%llu "
               "hook_calls=%llu sampled_calls=%llu pages=%llu "
               "sampled_touches=%llu migration_attempts=%llu "
               "migration_successes=%llu max_sampled_touches=%llu\n",
               modeName(config.mode), static_cast<int>(config.targetNode),
               config.hasTargetNode ? 1u : 0u,
               static_cast<unsigned long long>(config.samplePeriod),
               static_cast<unsigned long long>(config.threshold),
               static_cast<unsigned long long>(gHookCalls.load()),
               static_cast<unsigned long long>(gSampledCalls.load()),
               static_cast<unsigned long long>(pageStats.pages),
               static_cast<unsigned long long>(pageStats.sampledTouches),
               static_cast<unsigned long long>(pageStats.migrationAttempts),
               static_cast<unsigned long long>(pageStats.migrationSuccesses),
               static_cast<unsigned long long>(pageStats.maxSampledTouches));
}

uint64_t getPageSize() {
  static const uint64_t pageSize = [] {
    long value = ::sysconf(_SC_PAGESIZE);
    if (value <= 0)
      return kFallbackPageSize;
    return static_cast<uint64_t>(value);
  }();
  return pageSize;
}

void *pageAlignDown(void *addr) {
  uintptr_t value = reinterpret_cast<uintptr_t>(addr);
  uint64_t pageSize = getPageSize();
  return reinterpret_cast<void *>((value / pageSize) * pageSize);
}

bool movePageToTargetNode(void *page, int32_t targetNode) {
#if ARBITER_HAS_MOVE_PAGES
  if (!page || targetNode < 0)
    return false;

  void *pages[] = {page};
  int nodes[] = {targetNode};
  int status[] = {-1};
  long result =
      move_pages(/*pid=*/0, /*count=*/1, pages, nodes, status, MPOL_MF_MOVE);
  return result == 0 && status[0] == targetNode;
#else
  (void)page;
  (void)targetNode;
  return false;
#endif
}

bool shouldSample(const LockTouchConfig &config) {
  thread_local uint64_t sampleCounter = 0;
  uint64_t current = sampleCounter++;

  if (config.useMask)
    return (current & config.sampleMask) == 0;

  return (current % config.samplePeriod) == 0;
}

void lockTouchSlow(void *addr, uint32_t siteId,
                   const LockTouchConfig &config) {
  void *page = pageAlignDown(addr);
  bool migrationEnabled =
      config.mode == LockTouchMode::Migrate && config.hasTargetNode;

  bool shouldMigrate =
      lockPageRecordSample(page, siteId, config.threshold, migrationEnabled);
  if (!shouldMigrate)
    return;

  if (movePageToTargetNode(page, config.targetNode))
    lockPageMarkMigrated(page);
}

} // namespace

extern "C" void arbiter_lock_touch(void *addr, uint32_t site_id) {
  const LockTouchConfig &config = getConfig();
  if (config.statsEnabled)
    gHookCalls.fetch_add(1, std::memory_order_relaxed);

  if (!addr || config.mode == LockTouchMode::Off)
    return;

  if (!shouldSample(config))
    return;

  if (config.statsEnabled)
    gSampledCalls.fetch_add(1, std::memory_order_relaxed);

  lockTouchSlow(addr, site_id, config);
}
