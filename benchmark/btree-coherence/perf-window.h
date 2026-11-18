// Optional perf-stat FIFO control; initialization and validation stay uncounted.
#pragma once
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static inline void perf_window(bool enabled) {
  const char *control = getenv("ARBITER_MICRO_PERF_CONTROL");
  const char *ack = getenv("ARBITER_MICRO_PERF_ACK");
  if (!control && !ack) return;
  if (!control || !ack) {
    fprintf(stderr, "perf control requires both control and acknowledgement FIFOs\n");
    exit(EXIT_FAILURE);
  }
  // Keep the writer open between commands: EOF makes perf close its control
  // channel, so reopening it for disable would fail.
  static int ctl_fd = -1, ack_fd = -1;
  if (ctl_fd < 0) {
    ctl_fd = open(control, O_WRONLY | O_NONBLOCK);
    ack_fd = open(ack, O_RDONLY | O_NONBLOCK);
  }
  const char *command = enabled ? "enable\n" : "disable\n";
  // perf versions may include the trailing NUL in their acknowledgement.
  char reply[16];
  struct pollfd pending = {ack_fd, POLLIN, 0};
  if (ctl_fd < 0 || ack_fd < 0 ||
      write(ctl_fd, command, strlen(command)) != (ssize_t)strlen(command) ||
      poll(&pending, 1, 5000) != 1 || !(pending.revents & POLLIN) ||
      read(ack_fd, reply, sizeof(reply)) < 4 || memcmp(reply, "ack\n", 4)) {
    fprintf(stderr, "perf control handshake failed\n");
    exit(EXIT_FAILURE);
  }
  if (!enabled) {
    close(ack_fd);
    close(ctl_fd);
    ack_fd = ctl_fd = -1;
  }
}
