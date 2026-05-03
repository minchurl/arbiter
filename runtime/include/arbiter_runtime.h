#ifndef ARBITER_RUNTIME_H
#define ARBITER_RUNTIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void *arbiter_alloc(uint64_t size, uint64_t align);
void arbiter_dealloc(void *ptr);

#ifdef __cplusplus
}
#endif

#endif // ARBITER_RUNTIME_H
