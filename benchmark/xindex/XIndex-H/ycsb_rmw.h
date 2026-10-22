#pragma once

#include <cstdint>

namespace ycsb {

struct RmwResult {
  bool read_successful;
  bool update_successful;
};

// YCSB F is a sequential read and update, not an atomic fetch-add transaction.
// Keep both calls in the same worker and use the benchmark's supplied value,
// just as CoreWorkload uses a generated value rather than a value-dependent sum.
template <class Table, class Key, class Value>
RmwResult read_modify_write(Table &table, const Key &key, const Value &new_value,
                           uint32_t worker_id) {
  Value old_value{};
  const bool read_ok = table.get(key, old_value, worker_id);
  const bool update_ok = table.put(key, new_value, worker_id);
  return {read_ok, update_ok};
}

}  // namespace ycsb
