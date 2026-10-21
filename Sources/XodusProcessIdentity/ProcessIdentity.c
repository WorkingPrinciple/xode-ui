// SPDX-License-Identifier: GPL-3.0-only
#include "XodusProcessIdentity.h"
#include <libproc.h>
#include <unistd.h>

int xodus_process_matches(int32_t pid, uint64_t seconds, uint64_t microseconds) {
    uint64_t actual_seconds = 0, actual_microseconds = 0;
    return microseconds < 1000000 && xodus_process_start(pid, &actual_seconds, &actual_microseconds) &&
        actual_seconds == seconds && actual_microseconds == microseconds;
}

int xodus_process_start(int32_t pid, uint64_t *seconds, uint64_t *microseconds) {
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

int xodus_process_descends_from(int32_t pid, int32_t ancestor) {
    if (pid <= 1 || ancestor <= 1) return 0;
    for (int depth = 0; depth < 64 && pid > 1 && pid != ancestor; depth++) {
        struct proc_bsdinfo info = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info) ||
            info.pbi_uid != geteuid() || info.pbi_ppid == (uint32_t)pid) return 0;
        pid = (int32_t)info.pbi_ppid;
    }
    return pid == ancestor;
}
