#include "ycsb_rmw.h"

#include <cassert>
#include <vector>

struct Table {
  std::vector<char> calls;
  uint64_t value = 1;
  bool read_ok = true;
  bool write_ok = true;

  bool get(uint64_t key, uint64_t &out, uint32_t worker) {
    assert(key == 17 && worker == 3);
    calls.push_back('r');
    out = value;
    return read_ok;
  }
  bool put(uint64_t key, uint64_t next, uint32_t worker) {
    assert(key == 17 && worker == 3);
    calls.push_back('w');
    value = next;
    return write_ok;
  }
};

int main() {
  // Each logical RMW must make both calls, in order, on the same key/worker.
  for (bool read_ok : {false, true}) {
    for (bool write_ok : {false, true}) {
      Table table;
      table.read_ok = read_ok;
      table.write_ok = write_ok;
      auto result = ycsb::read_modify_write(table, uint64_t{17}, uint64_t{42}, 3);
      assert((table.calls == std::vector<char>{'r', 'w'}));
      assert(table.value == 42);
      assert(result.read_successful == read_ok);
      assert(result.update_successful == write_ok);
    }
  }
}
