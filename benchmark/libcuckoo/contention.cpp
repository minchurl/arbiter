// Existing-key workload: every successful update increments a value under
// libcuckoo's own lock. Verify the complete sum after workers join.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <libcuckoo/cuckoohash_map.hh>
#include <string>
#include <thread>
#include <vector>

using Table = libcuckoo::cuckoohash_map<uint64_t, uint64_t>;
struct alignas(64) Result {
  uint64_t reads = 0, writes = 0, failures = 0, checksum = 0;
};
struct Options {
  uint64_t keys = 1 << 20, hot = 1 << 16, threads = 32, operations = 1000000,
           reads = 50, seed = 1729;
  bool partitioned = false;
};
uint64_t random64(uint64_t &state) {
  state ^= state >> 12;
  state ^= state << 25;
  state ^= state >> 27;
  return state * UINT64_C(2685821657736338717);
}
void worker(Table &table, const Options &o, unsigned id, Result &result,
            std::atomic<unsigned> &ready, std::atomic<bool> &go) {
  uint64_t state = o.seed + id + 1;
  uint64_t reads = 0, writes = 0, failures = 0, checksum = 0;
  ready.fetch_add(1, std::memory_order_release);
  while (!go.load(std::memory_order_acquire))
    std::this_thread::yield();
  const uint64_t range = o.partitioned ? o.hot / o.threads : o.hot;
  const uint64_t base = o.partitioned ? range * id : 0;
  for (uint64_t i = 0; i < o.operations; ++i) {
    uint64_t r = random64(state), key = base + r % range;
    if ((r >> 32) % 100 < o.reads) {
      uint64_t value = 0;
      if (!table.find(key, value))
        ++failures;
      checksum += value;
      ++reads;
    } else {
      if (!table.update_fn(key, [](uint64_t &value) { ++value; }))
        ++failures;
      ++writes;
    }
  }
  result = {reads, writes, failures, checksum};
}
int main(int argc, char **argv) {
  try {
    Options o;
    for (int i = 1; i < argc; ++i) {
      std::string arg = argv[i];
      if (arg == "--partitioned") {
        o.partitioned = true;
        continue;
      }
      if (i + 1 == argc)
        throw std::runtime_error("missing option value");
      size_t end = 0;
      std::string text = argv[++i];
      uint64_t v = std::stoull(text, &end);
      if (text.empty() || text[0] == '-' || end != text.size())
        throw std::runtime_error("invalid integer");
      if (arg == "--keys")
        o.keys = v;
      else if (arg == "--hot")
        o.hot = v;
      else if (arg == "--threads")
        o.threads = v;
      else if (arg == "--operations")
        o.operations = v;
      else if (arg == "--reads")
        o.reads = v;
      else if (arg == "--seed")
        o.seed = v;
      else
        throw std::runtime_error("unknown option: " + arg);
    }
    if (!o.keys || !o.hot || o.hot > o.keys || !o.threads || o.threads > 256 ||
        !o.operations || o.reads > 100 ||
        (o.partitioned && o.hot % o.threads) || o.keys > (1ULL << 28) ||
        o.operations > UINT64_MAX / o.threads)
      throw std::runtime_error("invalid workload dimensions");
    Table table(o.keys * 2);
    for (uint64_t key = 0; key < o.keys; ++key)
      if (!table.insert(key, 0))
        throw std::runtime_error("prefill failed");
    const size_t hashpower = table.hashpower();
    std::vector<Result> results(o.threads);
    std::vector<std::thread> threads;
    threads.reserve(o.threads);
    std::atomic<unsigned> ready{0};
    std::atomic<bool> go{false};
    for (unsigned i = 0; i < o.threads; ++i)
      threads.emplace_back(worker, std::ref(table), std::cref(o), i,
                           std::ref(results[i]), std::ref(ready), std::ref(go));
    while (ready.load(std::memory_order_acquire) != o.threads)
      std::this_thread::yield();
    const auto start = std::chrono::steady_clock::now();
    go.store(true, std::memory_order_release);
    for (auto &thread : threads)
      thread.join();
    const double seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
            .count();
    uint64_t reads = 0, writes = 0, failures = 0, checksum = 0, sum = 0;
    for (const auto &r : results) {
      reads += r.reads;
      writes += r.writes;
      failures += r.failures;
      checksum += r.checksum;
    }
    for (uint64_t key = 0; key < o.keys; ++key) {
      uint64_t value = 0;
      if (!table.find(key, value))
        ++failures;
      sum += value;
    }
    bool valid = !failures && reads + writes == o.threads * o.operations &&
                 sum == writes && table.size() == o.keys &&
                 table.hashpower() == hashpower;
    std::cout << "{\"keys\":" << o.keys << ",\"hot\":" << o.hot
              << ",\"threads\":" << o.threads << ",\"read_pct\":" << o.reads
              << ",\"partitioned\":" << o.partitioned << ",\"seed\":" << o.seed
              << ",\"reads\":" << reads << ",\"updates\":" << writes
              << ",\"failures\":" << failures << ",\"value_sum\":" << sum
              << ",\"read_checksum\":" << checksum << ",\"seconds\":" << seconds
              << ",\"mops\":" << (reads + writes) / seconds / 1e6
              << ",\"valid\":" << (valid ? "true" : "false") << "}\n";
    return valid ? 0 : 1;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 2;
  }
}
