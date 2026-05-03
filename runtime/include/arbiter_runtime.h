#ifndef ARBITER_RUNTIME_H
#define ARBITER_RUNTIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum ArbiterPolicy : int32_t {
  ARBITER_POLICY_LOCAL = 0,
  ARBITER_POLICY_REMOTE_NUMA = 1,
  ARBITER_POLICY_CXL = 2,
};

void *arbiter_alloc(uint64_t size, uint64_t align, int32_t policy);
void arbiter_dealloc(void *ptr, uint64_t size, int32_t policy);

#ifdef __cplusplus
}
#endif

#endif // ARBITER_RUNTIME_H
