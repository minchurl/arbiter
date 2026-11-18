// Rewrite this fixture before linking: both call and invoke must retain the
// original allocation failure contract, including aligned and array forms.
#include <numaif.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <new>

namespace {
bool rejectBind = false;
unsigned handlerCalls = 0;
void stopRetrying() {
  ++handlerCalls;
  std::set_new_handler(nullptr);
}
void allowBinding() {
  ++handlerCalls;
  rejectBind = false;
}
void throwFromHandler() { throw 42; }
} // namespace

extern "C" long mbind(void *ptr, unsigned long size, int mode,
                      const unsigned long *mask, unsigned long maxnode,
                      unsigned flags) {
  if (rejectBind) {
    errno = EPERM;
    return -1;
  }
  return syscall(SYS_mbind, ptr, size, mode, mask, maxnode, flags);
}

int main() {
  std::set_new_handler(nullptr);
  volatile size_t huge = std::numeric_limits<size_t>::max();
  errno = 0;
  assert(std::malloc(huge) == nullptr && errno == ENOMEM);
  errno = 0;
  assert(std::calloc(huge, 2) == nullptr && errno == ENOMEM);
  unsigned caught = 0;
  try {
    (void)::operator new(huge);
  } catch (const std::bad_alloc &) {
    ++caught;
  }
  try {
    (void)::operator new[](huge);
  } catch (const std::bad_alloc &) {
    ++caught;
  }
  try {
    (void)::operator new(huge, std::align_val_t{4096});
  } catch (const std::bad_alloc &) {
    ++caught;
  }
  try {
    (void)::operator new[](huge, std::align_val_t{4096});
  } catch (const std::bad_alloc &) {
    ++caught;
  }
  assert(caught == 4);
  assert(::operator new(huge, std::nothrow) == nullptr);
  assert(::operator new[](huge, std::nothrow) == nullptr);
  assert(::operator new(huge, std::align_val_t{4096}, std::nothrow) == nullptr);
  assert(::operator new[](huge, std::align_val_t{4096}, std::nothrow) ==
         nullptr);

  std::set_new_handler(stopRetrying);
  try {
    (void)::operator new(huge);
    assert(false);
  } catch (const std::bad_alloc &) {
    assert(handlerCalls == 1);
  }
  std::set_new_handler(throwFromHandler);
  assert(::operator new(huge, std::nothrow) == nullptr);
  std::set_new_handler(nullptr);

  void *zero = std::malloc(0);
  assert(zero);
  errno = EDOM;
  std::free(zero);
  assert(errno == EDOM);
  zero = std::calloc(0, 8);
  assert(zero);
  std::free(zero);
  zero = ::operator new(0);
  assert(zero);
  ::operator delete(zero);

  // Recover on the SAME selected arena after new_handler returns. This is
  // standard C++ retry behavior, not a fallback to ordinary/local memory.
  rejectBind = true;
  std::set_new_handler(allowBinding);
  void *recovered = ::operator new(128, std::align_val_t{4096});
  assert(recovered && handlerCalls == 2);
  assert(reinterpret_cast<uintptr_t>(recovered) % 4096 == 0);
  std::set_new_handler(nullptr);
  ::operator delete(recovered, std::align_val_t{4096});
}
