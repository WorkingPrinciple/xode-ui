// SPDX-License-Identifier: GPL-3.0-only
#include "OdeProcessIdentity.h"
#include <libproc.h>
#include <unistd.h>

int ode_process_matches(int32_t pid, uint64_t seconds, uint64_t microseconds) {
    uint64_t actual_seconds = 0, actual_microseconds = 0;
    return microseconds < 1000000 && ode_process_start(pid, &actual_seconds, &actual_microseconds) &&
        actual_seconds == seconds && actual_microseconds == microseconds;
}

int ode_process_start(int32_t pid, uint64_t *seconds, uint64_t *microseconds) {
    struct proc_bsdinfo info = {0};
    if (pid <= 0 || seconds == NULL || microseconds == NULL ||
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) {
        return 0;
    }

    if (info.pbi_uid != geteuid()) return 0;
    *seconds = info.pbi_start_tvsec;
    *microseconds = info.pbi_start_tvusec;
    return 1;
}
