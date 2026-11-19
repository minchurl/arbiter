#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <thread>
extern "C" void arbiter_adaptive_register(uint32_t);
extern "C" void arbiter_adaptive_observe_counter(void *);
extern "C" void *arbiter_adaptive_counter();
alignas(64) static std::atomic<uint64_t> published{100};
int main(int argc, char **argv) {
  assert(argc == 2);
  arbiter_adaptive_register(42);
  if (!std::strcmp(argv[1], "owned")) {
    auto *slot = static_cast<uint64_t *>(arbiter_adaptive_counter());
    assert(reinterpret_cast<uintptr_t>(slot) % 64 == 0);
    __atomic_store_n(slot, 1234, __ATOMIC_RELAXED);
  } else {
    arbiter_adaptive_observe_counter(&published);
    if (!std::strcmp(argv[1], "duplicate"))
      arbiter_adaptive_observe_counter(&published);
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    assert(published.load() ==
           100); // The observer must never write the source.
    if (!std::strcmp(argv[1], "reset"))
      published = 50;
  }
}
