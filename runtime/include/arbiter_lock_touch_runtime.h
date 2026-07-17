#ifndef ARBITER_LOCK_TOUCH_RUNTIME_H
#define ARBITER_LOCK_TOUCH_RUNTIME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void arbiter_lock_touch(void *addr, uint32_t site_id);

#ifdef __cplusplus
}
#endif

#endif // ARBITER_LOCK_TOUCH_RUNTIME_H
