#define S3_EXIT_TEST
#define main observer_main
#include "exit-observe-v1.c"
#undef main
#include <assert.h>

static const char *scenario;
static int opens, closes, waits, exit_queries, signaled;
static HANDLE owned = (HANDLE)(uintptr_t)1;
static int mode(const char *name) { return !strcmp(scenario, name); }

HANDLE OpenProcess(DWORD access, BOOL inherit, DWORD pid)
{
    assert(access == (SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION));
    assert(!inherit && pid == 224);
    opens++;
    return mode("access-denied") ? NULL : owned;
}
DWORD GetProcessId(HANDLE handle)
{
    assert(handle == owned);
    return mode("pid-error") ? 0 : mode("wrong-pid") ? 228 : 224;
}
BOOL GetProcessTimes(HANDLE handle, FILETIME *created, FILETIME *exited,
    FILETIME *kernel, FILETIME *user)
{
    assert(handle == owned);
    (void)exited; (void)kernel; (void)user;
    created->dwHighDateTime = 0x12345678;
    created->dwLowDateTime = mode("wrong-creation") ? 2 : 1;
    return !mode("times-error");
}
BOOL QueryFullProcessImageNameA(HANDLE handle, DWORD flags, char *buffer, DWORD *size)
{
    assert(handle == owned && flags == 0 && *size == 32768);
    const char *path = mode("wrong-image") ? "Z:\\other\\DREDGE.exe"
        : mode("bad-image") ? "Z:\\bad\n\\DREDGE.exe" : "Z:\\stage\\DREDGE.exe";
    strcpy(buffer, path);
    *size = (DWORD)strlen(path);
    if (mode("truncated-image")) *size = 32768;
    return !mode("image-error");
}
DWORD WaitForSingleObject(HANDLE handle, DWORD timeout)
{
    assert(handle == owned);
    assert(timeout == (mode("identity") || mode("identity-exited") ? 0u : 500u));
    waits++;
    if (mode("timeout") || mode("still-active") || mode("identity")) return WAIT_TIMEOUT;
    if (mode("wait-error")) return WAIT_FAILED;
    if (mode("wait-unexpected")) return 17;
    signaled = 1;
    return WAIT_OBJECT_0;
}
BOOL GetExitCodeProcess(HANDLE handle, DWORD *code)
{
    assert(handle == owned && waits == 1 && signaled);
    exit_queries++;
    *code = mode("255") ? 255 : mode("ffffffff") ? UINT32_MAX
        : mode("259") ? 259 : 0;
    return !mode("exit-error");
}
BOOL CloseHandle(HANDLE handle)
{
    assert(handle == owned);
    closes++;
    return !mode("close-error");
}
DWORD GetLastError(void) { return 5; }

int main(int argc, char **argv)
{
    assert(argc == 3);
    scenario = argv[1];
    char *args[] = {"exit-observe", "wait", "224", "Z:\\stage\\DREDGE.exe",
        "1234567800000001", "500"};
    int count = 6;
    if (mode("identity") || mode("identity-exited")) {
        args[1] = "identity";
        count = 4;
    }
    if (mode("bad-pid")) args[2] = "4294967296";
    if (mode("signed-pid")) args[2] = "-1";
    if (mode("junk-pid")) args[2] = "224junk";
    if (mode("zero-pid")) args[2] = "0";
    if (mode("bad-path")) args[3] = "DREDGE.exe";
    if (mode("unicode-path")) args[3] = "Z:\\\xc3\xa9\\DREDGE.exe";
    if (mode("bad-creation")) args[4] = "0x1234567800000001";
    if (mode("zero-creation")) args[4] = "0000000000000000";
    if (mode("bad-timeout")) args[5] = "600001";
    if (mode("zero-timeout")) args[5] = "0";
    if (mode("bad-argc")) count = 1;
    int result = observer_main(count, args);
    assert(result == atoi(argv[2]));
    assert(closes == (opens && !mode("access-denied") ? 1 : 0));
    assert(exit_queries == (signaled && !mode("identity-exited") ? 1 : 0));
    return 0;
}
