// Sample live benchmark objects outside the measured interval.
#pragma once

#include <numaif.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static inline void sample_pages(const char *label, void *first, void *middle,
                                void *last) {
  void *pages[] = {first, middle, last};
  int status[3] = {-1, -1, -1};
  const long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0)
    exit(EXIT_FAILURE);
  for (int i = 0; i < 3; ++i)
    pages[i] = (void *)((uintptr_t)pages[i] & ~((uintptr_t)page_size - 1));
  if (move_pages(0, 3, pages, NULL, status, 0) != 0) {
    perror("move_pages");
    exit(EXIT_FAILURE);
  }
  printf("placement object=%s nodes=%d,%d,%d\n", label, status[0], status[1],
         status[2]);
}
