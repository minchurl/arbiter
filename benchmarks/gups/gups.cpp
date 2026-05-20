extern "C" unsigned long long
gups_run_table(unsigned long long *table, long long entries, long long updates,
               unsigned long long seed, long long hotEntries,
               unsigned long long hotAccessPercent);

#ifndef GUPS_EXTERNAL_KERNEL
extern "C" unsigned long long gups_kernel(long long entries, long long updates,
                                          unsigned long long seed,
                                          long long hotEntries,
                                          unsigned long long hotAccessPercent) {
  unsigned long long *table = new unsigned long long[entries];
  unsigned long long elapsedNs = gups_run_table(table, entries, updates, seed,
                                                hotEntries, hotAccessPercent);
  delete[] table;
  return elapsedNs;
}
#endif

#ifndef GUPS_FRONTEND_ONLY

#include <cerrno>
#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <string>

extern "C" unsigned long long gups_kernel(long long entries, long long updates,
                                          unsigned long long seed,
                                          long long hotEntries,
                                          unsigned long long hotAccessPercent);

namespace {

constexpr uint64_t kMiB = 1024ULL * 1024ULL;
constexpr uint64_t kRandomAccessPoly = 0x0000000000000007ULL;
volatile uint64_t gChecksumSink = 0;

struct Options {
  uint64_t tableMiB = 256;
  uint64_t updates = 0;
  uint64_t seed = 1;
  uint64_t hotRegionPercent = 100;
  uint64_t hotAccessPercent = 100;
  std::string mode = "system";
  bool csv = false;
  bool help = false;
};

void printUsage(const char *argv0) {
  std::printf(
      "usage: %s [options]\n"
      "\n"
      "Options:\n"
      "  --table-mib N  Table size in MiB before power-of-two rounding "
      "(default: 256)\n"
      "  --updates N    Total random updates (default: 4 * table entries)\n"
      "  --seed N       Nonzero random stream seed (default: 1)\n"
      "  --hot-region-percent N  Percent of table treated as hot "
      "(default: 100)\n"
      "  --hot-access-percent N  Percent of updates targeting hot region "
      "(default: 100)\n"
      "  --mode NAME    Label printed in output (default: system)\n"
      "  --csv          Print one CSV row without a header\n"
      "  --help         Show this help\n",
      argv0);
}

bool parseUint64(const char *text, const char *name, uint64_t &value) {
  errno = 0;
  char *end = nullptr;
  unsigned long long parsed = std::strtoull(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0') {
    std::fprintf(stderr, "gups: invalid %s=%s\n", name, text);
    return false;
  }
  value = static_cast<uint64_t>(parsed);
  return true;
}

const char *optionValue(int argc, char **argv, int &index,
                        const char *optionName) {
  const char *arg = argv[index];
  size_t nameLen = std::strlen(optionName);
  if (std::strncmp(arg, optionName, nameLen) == 0 && arg[nameLen] == '=')
    return arg + nameLen + 1;

  if (std::strcmp(arg, optionName) == 0) {
    if (index + 1 >= argc) {
      std::fprintf(stderr, "gups: missing value for %s\n", optionName);
      return nullptr;
    }
    ++index;
    return argv[index];
  }

  return nullptr;
}

bool parseArgs(int argc, char **argv, Options &options) {
  for (int i = 1; i < argc; ++i) {
    const char *value = nullptr;
    if ((value = optionValue(argc, argv, i, "--table-mib"))) {
      if (!parseUint64(value, "--table-mib", options.tableMiB))
        return false;
    } else if ((value = optionValue(argc, argv, i, "--updates"))) {
      if (!parseUint64(value, "--updates", options.updates))
        return false;
    } else if ((value = optionValue(argc, argv, i, "--seed"))) {
      if (!parseUint64(value, "--seed", options.seed))
        return false;
    } else if ((value = optionValue(argc, argv, i, "--hot-region-percent"))) {
      if (!parseUint64(value, "--hot-region-percent", options.hotRegionPercent))
        return false;
    } else if ((value = optionValue(argc, argv, i, "--hot-access-percent"))) {
      if (!parseUint64(value, "--hot-access-percent", options.hotAccessPercent))
        return false;
    } else if ((value = optionValue(argc, argv, i, "--mode"))) {
      options.mode = value;
    } else if (std::strcmp(argv[i], "--csv") == 0) {
      options.csv = true;
    } else if (std::strcmp(argv[i], "--help") == 0) {
      options.help = true;
    } else {
      std::fprintf(stderr, "gups: unknown option: %s\n", argv[i]);
      return false;
    }
  }

  if (options.tableMiB == 0) {
    std::fprintf(stderr, "gups: --table-mib must be nonzero\n");
    return false;
  }
  if (options.seed == 0) {
    std::fprintf(stderr, "gups: --seed must be nonzero\n");
    return false;
  }
  if (options.hotRegionPercent == 0 || options.hotRegionPercent > 100) {
    std::fprintf(stderr,
                 "gups: --hot-region-percent must be between 1 and 100\n");
    return false;
  }
  if (options.hotAccessPercent > 100) {
    std::fprintf(stderr,
                 "gups: --hot-access-percent must be between 0 and 100\n");
    return false;
  }
  if (options.hotRegionPercent == 100 && options.hotAccessPercent != 100) {
    std::fprintf(stderr,
                 "gups: --hot-access-percent must be 100 when the hot region "
                 "covers the whole table\n");
    return false;
  }
  return true;
}

uint64_t floorPowerOfTwo(uint64_t value) {
  if (value == 0)
    return 0;
  uint64_t result = 1;
  while (result <= value / 2)
    result <<= 1;
  return result;
}

uint64_t nextRandom(uint64_t state) {
  return (state << 1) ^
         ((state & (1ULL << 63)) != 0 ? kRandomAccessPoly : 0ULL);
}

uint64_t computeHotEntries(uint64_t entries, uint64_t hotRegionPercent) {
  if (hotRegionPercent == 100)
    return entries;

  uint64_t hotEntries = (entries / 100) * hotRegionPercent +
                        ((entries % 100) * hotRegionPercent) / 100;
  if (hotEntries == 0)
    hotEntries = 1;
  if (hotEntries >= entries)
    hotEntries = entries - 1;
  return hotEntries;
}

uint64_t chooseIndex(uint64_t value, uint64_t entries, uint64_t hotEntries,
                     uint64_t hotAccessPercent) {
  if (hotEntries == entries)
    return value & (entries - 1);

  uint64_t choice = (value >> 32) % 100;
  if (choice < hotAccessPercent)
    return value % hotEntries;

  uint64_t coldEntries = entries - hotEntries;
  return hotEntries + (value % coldEntries);
}

void printCsv(const Options &options, uint64_t actualBytes, uint64_t entries,
              uint64_t hotEntries, uint64_t updates, double elapsedSeconds,
              uint64_t checksumSink) {
  const char *targetNode = std::getenv("ARBITER_TARGET_NODE");
  double actualMiB = static_cast<double>(actualBytes) / kMiB;
  double gups = elapsedSeconds > 0.0
                    ? static_cast<double>(updates) / elapsedSeconds / 1.0e9
                    : 0.0;
  double nsPerUpdate =
      updates > 0 ? elapsedSeconds * 1.0e9 / static_cast<double>(updates) : 0.0;
  std::printf("%s,%" PRIu64 ",%.3f,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64
              ",%" PRIu64 ",%.9f,%.9f,%.3f,0x%016" PRIx64 ",%s\n",
              options.mode.c_str(), options.tableMiB, actualMiB, entries,
              options.hotRegionPercent, hotEntries, options.hotAccessPercent,
              updates, elapsedSeconds, gups, nsPerUpdate, checksumSink,
              targetNode ? targetNode : "");
}

void printHuman(const Options &options, uint64_t actualBytes, uint64_t entries,
                uint64_t hotEntries, uint64_t updates, double elapsedSeconds,
                uint64_t checksumSink) {
  const char *targetNode = std::getenv("ARBITER_TARGET_NODE");
  double actualMiB = static_cast<double>(actualBytes) / kMiB;
  double gups = elapsedSeconds > 0.0
                    ? static_cast<double>(updates) / elapsedSeconds / 1.0e9
                    : 0.0;
  double nsPerUpdate =
      updates > 0 ? elapsedSeconds * 1.0e9 / static_cast<double>(updates) : 0.0;

  std::printf("gups\n");
  std::printf("  mode: %s\n", options.mode.c_str());
  std::printf("  arbiter_target_node: %s\n", targetNode ? targetNode : "");
  std::printf("  requested_table_mib: %" PRIu64 "\n", options.tableMiB);
  std::printf("  actual_table_mib: %.3f\n", actualMiB);
  std::printf("  table_entries: %" PRIu64 "\n", entries);
  std::printf("  hot_region_percent: %" PRIu64 "\n", options.hotRegionPercent);
  std::printf("  hot_entries: %" PRIu64 "\n", hotEntries);
  std::printf("  hot_access_percent: %" PRIu64 "\n", options.hotAccessPercent);
  std::printf("  updates: %" PRIu64 "\n", updates);
  std::printf("  elapsed_s: %.9f\n", elapsedSeconds);
  std::printf("  gups: %.9f\n", gups);
  std::printf("  ns_per_update: %.3f\n", nsPerUpdate);
  std::printf("  checksum_sink: 0x%016" PRIx64 "\n", checksumSink);
}

} // namespace

extern "C" unsigned long long
gups_run_table(unsigned long long *table, long long entries, long long updates,
               unsigned long long seed, long long hotEntries,
               unsigned long long hotAccessPercent) {
  for (long long i = 0; i < entries; ++i)
    table[i] = static_cast<unsigned long long>(i);

  unsigned long long state = seed;
  unsigned long long checksum = 0;
  unsigned long long entriesU = static_cast<unsigned long long>(entries);
  unsigned long long hotEntriesU = static_cast<unsigned long long>(hotEntries);

  auto begin = std::chrono::steady_clock::now();
  for (long long i = 0; i < updates; ++i) {
    state = nextRandom(state);
    unsigned long long index =
        chooseIndex(state, entriesU, hotEntriesU, hotAccessPercent);
    unsigned long long updated = table[index] ^ state;
    table[index] = updated;
    checksum ^= updated;
  }
  auto end = std::chrono::steady_clock::now();

  gChecksumSink ^= checksum;
  auto elapsed =
      std::chrono::duration_cast<std::chrono::nanoseconds>(end - begin);
  return static_cast<unsigned long long>(elapsed.count());
}

int main(int argc, char **argv) {
  Options options;
  if (!parseArgs(argc, argv, options))
    return 2;
  if (options.help) {
    printUsage(argv[0]);
    return 0;
  }

  if (options.tableMiB > std::numeric_limits<uint64_t>::max() / kMiB) {
    std::fprintf(stderr, "gups: table size overflows\n");
    return 2;
  }

  uint64_t requestedBytes = options.tableMiB * kMiB;
  uint64_t entries = floorPowerOfTwo(requestedBytes / sizeof(uint64_t));
  if (entries == 0 ||
      entries > static_cast<uint64_t>(std::numeric_limits<long long>::max())) {
    std::fprintf(stderr, "gups: table is too small or too large\n");
    return 2;
  }

  if (options.updates == 0) {
    if (entries > std::numeric_limits<uint64_t>::max() / 4) {
      std::fprintf(stderr, "gups: default update count overflows\n");
      return 2;
    }
    options.updates = entries * 4;
  }

  if (options.updates >
      static_cast<uint64_t>(std::numeric_limits<long long>::max())) {
    std::fprintf(stderr, "gups: --updates is too large\n");
    return 2;
  }

  uint64_t actualBytes = entries * sizeof(uint64_t);
  uint64_t hotEntries = computeHotEntries(entries, options.hotRegionPercent);
  unsigned long long elapsedNs =
      gups_kernel(static_cast<long long>(entries),
                  static_cast<long long>(options.updates), options.seed,
                  static_cast<long long>(hotEntries), options.hotAccessPercent);
  double elapsedSeconds = static_cast<double>(elapsedNs) / 1.0e9;
  uint64_t checksumSink = gChecksumSink;

  if (options.csv)
    printCsv(options, actualBytes, entries, hotEntries, options.updates,
             elapsedSeconds, checksumSink);
  else
    printHuman(options, actualBytes, entries, hotEntries, options.updates,
               elapsedSeconds, checksumSink);

  return 0;
}

#endif
