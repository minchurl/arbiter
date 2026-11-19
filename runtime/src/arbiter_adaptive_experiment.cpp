// Research controller: one compiler-selected progress domain, no argv parsing.
// Placement changes affect resident pages of registered companion sites only.
// This is intentionally separate from the default allocation runtime.
#include "arbiter_runtime_site.h"
#include <numa.h>
#include <numaif.h>
#include <sched.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
struct alignas(64) Counter {
  std::atomic<uint64_t> value{0};
};
struct Source {
  void *address;
  uint64_t previous = 0;
};
struct State {
  std::mutex mutex;
  std::vector<Source>
      counters; // Owned slots or process-lifetime global storage.
  std::vector<uint32_t> sites;
  std::atomic<bool> stopping{false};
  std::atomic<bool> invalidProgress{false};
  std::once_flag started;
  std::thread controller;
  int local = -1, target = -1;
  uint64_t budget = 4ULL << 30;
  bool observe = false;
  Clock::time_point start = Clock::now();
};
State &state() {
  static State *s = new State;
  return *s;
}
double elapsed() {
  return std::chrono::duration<double>(Clock::now() - state().start).count();
}
bool pause(double seconds) {
  auto until = Clock::now() + std::chrono::duration<double>(seconds);
  while (!state().stopping && Clock::now() < until)
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
  return !state().stopping;
}
uint64_t progress() {
  auto &s = state();
  std::lock_guard<std::mutex> lock(s.mutex);
  uint64_t n = 0;
  for (auto &counter : s.counters) {
    uint64_t value = __atomic_load_n(static_cast<uint64_t *>(counter.address),
                                     __ATOMIC_RELAXED);
    if (value < counter.previous)
      s.invalidProgress = true;
    counter.previous = value;
    n += value;
  }
  return n;
}
double sample(unsigned ratio, const char *phase, double seconds = 2) {
  double begin = elapsed();
  uint64_t before = progress();
  if (!pause(seconds))
    return 0;
  uint64_t after = progress();
  double end = elapsed();
  if (after < before || state().invalidProgress)
    return 0;
  double rate = (after - before) / (end - begin);
  std::fprintf(
      stderr,
      "arbiter-adaptive "
      "{\"event\":\"sample\",\"phase\":\"%s\",\"time\":%.6f,\"seconds\":%.6f,"
      "\"ratio_bp\":%u,\"progress\":%llu,\"rate\":%.3f}\n",
      phase, end, end - begin, ratio,
      static_cast<unsigned long long>(after - before), rate);
  return rate;
}
double measure(unsigned ratio, const char *phase, double abortBelow = 0) {
  std::vector<double> values;
  for (int i = 0; i < 3 && !state().stopping; ++i) {
    double rate = sample(ratio, phase);
    values.push_back(rate);
    if (rate > 0 && rate < abortBelow)
      return rate;
  }
  if (values.size() != 3 || values.front() == 0)
    return 0;
  std::sort(values.begin(), values.end());
  return values[1];
}
struct Range {
  uintptr_t start;
  uint64_t bytes;
};
void collect(void *address, uint64_t bytes, void *context) {
  static_cast<std::vector<Range> *>(context)->push_back(
      {reinterpret_cast<uintptr_t>(address), bytes});
}
// Kernel page status, including partial migration failure, is authoritative.
// No MPOL_MF_MOVE_ALL, data writes, or page faults to populate unused capacity.
bool query(const std::vector<void *> &pages, std::vector<int> &nodes) {
  nodes.resize(pages.size());
  for (size_t i = 0; i < pages.size(); i += 4096) {
    size_t n = std::min<size_t>(4096, pages.size() - i);
    if (move_pages(0, n, const_cast<void **>(pages.data() + i), nullptr,
                   nodes.data() + i, 0) < 0)
      return false;
  }
  return true;
}
bool relocate(unsigned ratio) {
  auto &s = state();
  double begin = elapsed();
  uint64_t before = progress();
  std::vector<Range> ranges;
  for (auto id : s.sites)
    if (arbiter_visit_site_extents(id, collect, &ranges))
      return false;
  std::sort(ranges.begin(), ranges.end(),
            [](auto a, auto b) { return a.start < b.start; });
  const size_t page = sysconf(_SC_PAGESIZE);
  std::vector<void *> mapped;
  for (auto range : ranges)
    for (uint64_t offset = 0; offset < range.bytes; offset += page)
      mapped.push_back(reinterpret_cast<void *>(range.start + offset));
  std::vector<int> nodes;
  if (!query(mapped, nodes))
    return false;
  std::vector<void *> resident;
  std::vector<int> current;
  for (size_t i = 0; i < mapped.size(); ++i) {
    if (nodes[i] >= 0) {
      resident.push_back(mapped[i]);
      current.push_back(nodes[i]);
    } else if (nodes[i] != -ENOENT && nodes[i] != -EFAULT)
      return false;
  }
  size_t wanted = std::min<uint64_t>(resident.size() * uint64_t(ratio) / 10000,
                                     s.budget / page);
  size_t moved = 0, failed = 0;
  // Demote first so transitions do not temporarily exceed the resident budget.
  for (bool promotion : {false, true}) {
    std::vector<void *> addresses;
    std::vector<int> target;
    for (size_t i = 0; i < resident.size(); ++i) {
      int desired = i < wanted ? s.target : s.local;
      if (current[i] != desired && (desired == s.target) == promotion) {
        addresses.push_back(resident[i]);
        target.push_back(desired);
      }
    }
    for (size_t i = 0; i < addresses.size() && !s.stopping; i += 4096) {
      size_t n = std::min<size_t>(4096, addresses.size() - i);
      std::vector<int> status(n, -999);
      long rc = move_pages(0, n, addresses.data() + i, target.data() + i,
                           status.data(), MPOL_MF_MOVE);
      if (rc < 0)
        return false;
      for (size_t j = 0; j < n; ++j) {
        if (status[j] == target[i + j])
          ++moved;
        else
          ++failed;
      }
    }
    if (failed || s.stopping)
      break;
  }
  std::vector<int> final;
  if (!query(resident, final))
    return false;
  size_t actual = 0, missing = 0, mismatch = 0;
  for (size_t i = 0; i < final.size(); ++i) {
    if (final[i] == s.target)
      ++actual;
    if (final[i] < 0)
      ++missing;
    if (final[i] != (i < wanted ? s.target : s.local))
      ++mismatch;
  }
  double end = elapsed();
  uint64_t after = progress();
  std::fprintf(
      stderr,
      "arbiter-adaptive "
      "{\"event\":\"migration\",\"time\":%.6f,\"seconds\":%.6f,\"ratio_bp\":%u,"
      "\"resident_pages\":%zu,\"wanted_pages\":%zu,\"target_pages\":%zu,"
      "\"moved\":%zu,\"failed\":%zu,\"missing\":%zu,\"mismatch\":%zu,"
      "\"progress\":%llu,\"budget_bytes\":%llu,\"cancelled\":%d}\n",
      end, end - begin, ratio, resident.size(), wanted, actual, moved, failed,
      missing, mismatch, static_cast<unsigned long long>(after - before),
      static_cast<unsigned long long>(s.budget), int(s.stopping.load()));
  return !failed && !mismatch && actual * page <= s.budget && !resident.empty();
}
void decision(const char *action, unsigned ratio, double reference,
              double rate) {
  std::fprintf(stderr,
               "arbiter-adaptive "
               "{\"event\":\"decision\",\"time\":%.6f,\"action\":\"%s\","
               "\"ratio_bp\":%u,\"reference\":%.3f,\"rate\":%.3f}\n",
               elapsed(), action, ratio, reference, rate);
}
void control() {
  auto &s = state();
  while (!s.stopping && !progress())
    if (!pause(.1))
      return;
  if (!pause(3) || s.invalidProgress)
    return;
  if (s.observe) {
    while (!s.stopping)
      sample(0, "observe");
    return;
  }
  unsigned best = 0, current = 0;
  double baseline = measure(0, "baseline"), bestRate = baseline;
  if (!baseline)
    return;
  // The same coarse ladder and acceptance rules apply to every executable.
  // A bad probe rolls back, instead of assuming more CXL is always better.
  for (unsigned candidate : {1250u, 2500u, 5000u}) {
    if (s.stopping)
      return;
    if (s.invalidProgress) {
      relocate(0);
      decision("invalid-progress", 0, 0, 0);
      return;
    }
    if (!relocate(candidate)) {
      if (!s.stopping) {
        bool ok = relocate(0);
        decision(ok ? "migration-failed-restored" : "migration-failed-partial",
                 0, 0, 0);
      }
      return;
    }
    current = candidate;
    if (!pause(2))
      return;
    double rate = measure(candidate, "probe", bestRate * .85);
    if (!rate) {
      if (s.invalidProgress && !s.stopping) {
        relocate(0);
        decision("invalid-progress", 0, 0, 0);
      }
      return;
    }
    if (rate > bestRate * 1.02) {
      best = candidate;
      bestRate = rate;
      decision("accept", best, baseline, rate);
    } else
      decision("reject", candidate, bestRate, rate);
    if (rate < bestRate * .97)
      break;
  }
  if (s.stopping)
    return;
  if (current != best && !relocate(best)) {
    decision("rollback-failed", best, 0, 0);
    return;
  }
  current = best;
  if (!pause(2))
    return;
  double reference = measure(current, "settled");
  decision("hold", current, baseline, reference);
  unsigned bad = 0;
  while (!s.stopping) {
    if (s.invalidProgress) {
      bool restored = relocate(0);
      decision(restored ? "invalid-progress-restored"
                        : "invalid-progress-partial",
               0, 0, 0);
      return;
    }
    double rate = sample(current, "monitor");
    if (!rate)
      continue;
    bad = rate < reference * .85 ? bad + 1 : 0;
    if (bad < 3 || current == 0)
      continue;
    // Compare against fresh progress at the degraded condition, not the old
    // peak. A slowdown can be a phase/load change, not a placement problem.
    double degraded = measure(current, "degraded");
    if (s.stopping)
      return;
    if (!relocate(0)) {
      decision("phase-rollback-failed", current, 0, 0);
      return;
    }
    if (!pause(2))
      return;
    double local = measure(0, "phase-local");
    if (s.stopping)
      return;
    if (local >= degraded * .98) {
      decision("phase-keep-local", 0, degraded, local);
      current = 0;
      reference = local;
    } else {
      if (!relocate(current)) {
        decision("phase-restore-failed", current, 0, 0);
        return;
      }
      decision("phase-restore", current, local, degraded);
      reference = degraded;
    }
    bad = 0;
  }
}
void finish() {
  auto &s = state();
  s.stopping = true;
  if (s.controller.joinable())
    s.controller.join();
  uint64_t completed = progress();
  size_t active = std::count_if(s.counters.begin(), s.counters.end(),
                                [](const Source &x) { return x.previous > 0; });
  std::fprintf(
      stderr,
      "arbiter-adaptive "
      "{\"event\":\"finish\",\"time\":%.6f,\"progress\":%llu,\"sources\":%zu,"
      "\"active_sources\":%zu,\"invalid_progress\":%d}\n",
      elapsed(), static_cast<unsigned long long>(completed), s.counters.size(),
      active, int(s.invalidProgress.load()));
}
} // namespace

extern "C" void arbiter_adaptive_register(uint32_t site) {
  auto &s = state();
  if (s.sites.empty()) {
    s.local = numa_node_of_cpu(sched_getcpu());
    const char *target = std::getenv("ARBITER_TARGET_NODE");
    if (!target) {
      std::fputs("adaptive: target required\n", stderr);
      std::abort();
    }
    s.target = std::atoi(target);
    const char *mode = std::getenv("ARBITER_ADAPTIVE_MODE");
    if (mode && std::strcmp(mode, "adapt") && std::strcmp(mode, "observe"))
      std::abort();
    s.observe = mode && !std::strcmp(mode, "observe");
    if (s.local < 0 || s.local == s.target)
      std::abort();
  }
  // First touch stays local. Migration uses a separate, current-resident
  // budget; it does not reinterpret the fixed plan's lifetime mapping
  // accounting.
  if (arbiter_set_site_placement(site, s.local, 0, 0)) {
    std::perror("adaptive registration");
    std::abort();
  }
  if (s.sites.empty())
    std::atexit(finish);
  s.sites.push_back(site);
}
namespace {
void startController() {
  auto &s = state();
  std::call_once(s.started, [&] {
    s.start = Clock::now();
    s.controller = std::thread([] {
      try {
        control();
      } catch (...) {
        std::fputs("arbiter-adaptive {\"event\":\"controller-exception\"}\n",
                   stderr);
      }
    });
  });
}
} // namespace
extern "C" void arbiter_adaptive_observe_counter(void *address) {
  // A shared address from two worker registrations cannot be assumed to be
  // independent per-worker progress. Reject it rather than double-count it.
  auto &s = state();
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    if (std::any_of(s.counters.begin(), s.counters.end(),
                    [&](const Source &x) { return x.address == address; }))
      s.invalidProgress = true;
    else
      s.counters.push_back({address});
  }
  startController();
}
extern "C" void arbiter_adaptive_observe_range(void *address, uint64_t count,
                                               uint64_t stride) {
  auto &s = state();
  {
    std::lock_guard<std::mutex> lock(s.mutex);
    for (uint64_t i = 0; i < count; ++i)
      s.counters.push_back({static_cast<char *>(address) + i * stride});
  }
  startController();
}
extern "C" void *arbiter_adaptive_counter() {
  static_assert(std::atomic<uint64_t>::is_always_lock_free);
  thread_local Counter *counter = nullptr;
  auto &s = state();
  if (!counter) {
    counter = new (std::nothrow) Counter;
    if (!counter)
      std::abort();
    {
      std::lock_guard<std::mutex> lock(s.mutex);
      s.counters.push_back({&counter->value});
    }
    startController();
  }
  return &counter->value;
}
