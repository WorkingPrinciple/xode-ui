// SPDX-License-Identifier: GPL-3.0-only
#include <stdint.h>

int ode_process_matches(int32_t pid, uint64_t seconds, uint64_t microseconds);
int ode_process_start(int32_t pid, uint64_t *seconds, uint64_t *microseconds);
