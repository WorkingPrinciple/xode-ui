// SPDX-License-Identifier: GPL-3.0-only
#include <stdint.h>

int xodus_process_matches(int32_t pid, uint64_t seconds, uint64_t microseconds);
int xodus_process_start(int32_t pid, uint64_t *seconds, uint64_t *microseconds);
