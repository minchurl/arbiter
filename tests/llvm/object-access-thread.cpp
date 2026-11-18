#include <atomic>
#include <list>
#include <thread>
#include <vector>
struct alignas(64) Counter {
  std::atomic<unsigned long> value{0};
};
struct Owner {
  std::list<std::vector<Counter>> counters;
  unsigned long *data;
};
extern void escape(void *);
__attribute__((noinline)) void worker(Owner *owner) {
  owner->counters.back()[0].value.fetch_add(1, std::memory_order_relaxed);
  // A separate allocation in the actual worker exercises reachability.
  auto *temporary = new unsigned long[8];
  escape(temporary);
  delete[] temporary;
}
int main() {
  Owner owner;
  owner.counters.emplace_back(16);
  owner.data = new unsigned long[16];
  std::thread t(worker, &owner);
  std::thread lambda([&] { worker(&owner); });
  t.join();
  lambda.join();
  escape(owner.data);
  delete[] owner.data;
  return owner.counters.back()[0].value.load() == 2 ? 0 : 1;
}
