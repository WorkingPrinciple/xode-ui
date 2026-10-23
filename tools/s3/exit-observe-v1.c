#ifdef S3_EXIT_TEST
#include "exit-test-win32.h"
#else
#define _WIN32_WINNT 0x0600
#include <windows.h>
#endif
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(sizeof(DWORD) == 4, "Exit codes must be full 32-bit DWORDs");

static int decimal(const char *text, uint64_t maximum, uint64_t *value)
{
    if (!*text || strspn(text, "0123456789") != strlen(text))
        return 0;
    char *end;
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, 10);
    if (errno || *end || !parsed || parsed > maximum)
        return 0;
    *value = (uint64_t)parsed;
    return 1;
}

static int creation_number(const char *text, uint64_t *value)
{
    if (strlen(text) != 16 || strspn(text, "0123456789abcdefABCDEF") != 16)
        return 0;
    *value = (uint64_t)strtoull(text, NULL, 16);
    return *value != 0;
}

static int ascii_path(const char *text)
{
    size_t length = strlen(text);
    if (length < 4 || length >= 32768 ||
        !((text[0] >= 'A' && text[0] <= 'Z') ||
          (text[0] >= 'a' && text[0] <= 'z')) ||
        text[1] != ':' || text[2] != '\\')
        return 0;
    for (size_t i = 0; i < length; i++)
        if ((unsigned char)text[i] < 32 || (unsigned char)text[i] > 126)
            return 0;
    return 1;
}

static void json_string(const char *text)
{
    putchar('"');
    for (; *text; text++) {
        if (*text == '"' || *text == '\\')
            putchar('\\');
        putchar(*text);
    }
    putchar('"');
}

static int failure(const char *stage, DWORD error, int code)
{
    printf("{\"event\":\"failure\",\"stage\":\"%s\",\"win32_error\":%" PRIu32
        ",\"observer_exit\":%d}\n", stage, (uint32_t)error, code);
    return code;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    uint64_t pid, timeout = 0, expected_creation = 0;
    int discover = argc == 4 && !strcmp(argv[1], "identity");
    int observe = argc == 6 && !strcmp(argv[1], "wait");
    if ((!discover && !observe) ||
        !decimal(argv[2], UINT32_MAX, &pid) || !ascii_path(argv[3]) ||
        (observe && (!creation_number(argv[4], &expected_creation) ||
                     !decimal(argv[5], 600000, &timeout)))) {
        fprintf(stderr, "usage: exit-observe identity WINDOWS_PID EXACT_ASCII_EXE\n"
            "   or: exit-observe wait WINDOWS_PID EXACT_ASCII_EXE CREATION_HEX16 WAIT_MS(1..600000)\n");
        return failure("arguments", 0, 2);
    }
    HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
        FALSE, (DWORD)pid);
    if (!process)
        return failure("OpenProcess", GetLastError(), 3);
    int result;
    FILETIME created, exited, kernel, user;
    DWORD actual_pid = GetProcessId(process);
    if (!actual_pid) {
        result = failure("GetProcessId", GetLastError(), 4);
        goto close;
    }
    if (!GetProcessTimes(process, &created, &exited, &kernel, &user)) {
        result = failure("GetProcessTimes", GetLastError(), 4);
        goto close;
    }
    char image[32768] = {0};
    DWORD length = sizeof(image);
    if (!QueryFullProcessImageNameA(process, 0, image, &length)) {
        result = failure("QueryFullProcessImageNameA", GetLastError(), 4);
        goto close;
    }
    if (length >= sizeof(image) || image[length] || strlen(image) != length ||
        !ascii_path(image)) {
        result = failure("invalid_image", 0, 4);
        goto close;
    }
    uint64_t creation = ((uint64_t)created.dwHighDateTime << 32) | created.dwLowDateTime;
    printf("{\"event\":\"identity\",\"windows_pid\":%" PRIu32
        ",\"creation_hex\":\"%016" PRIx64 "\",\"image\":",
        (uint32_t)actual_pid, creation);
    json_string(image);
    printf("}\n");
    if (actual_pid != pid || strcmp(image, argv[3]) || !creation ||
        (observe && creation != expected_creation)) {
        result = failure("identity_mismatch", 0, 4);
        goto close;
    }
    if (observe)
        printf("{\"event\":\"armed\",\"wait_ms\":%" PRIu64 "}\n", timeout);
    DWORD waited = WaitForSingleObject(process, (DWORD)timeout);
    if (discover && waited == WAIT_TIMEOUT) {
        printf("{\"event\":\"identity_ready\",\"observer_exit\":0}\n");
        result = 0;
        goto close;
    }
    if (discover && waited == WAIT_OBJECT_0) {
        result = failure("identity_already_exited", 0, 4);
        goto close;
    }
    if (waited == WAIT_TIMEOUT) {
        printf("{\"event\":\"timeout\",\"observer_exit\":5}\n");
        result = 5;
        goto close;
    }
    if (waited != WAIT_OBJECT_0) {
        result = failure("WaitForSingleObject",
            waited == WAIT_FAILED ? GetLastError() : waited, 6);
        goto close;
    }
    DWORD code;
    if (!GetExitCodeProcess(process, &code)) {
        result = failure("GetExitCodeProcess", GetLastError(), 7);
        goto close;
    }
    printf("{\"event\":\"process_exit\",\"wait_signaled\":true,"
        "\"exit_dword\":%" PRIu32 ",\"exit_hex\":\"0x%08" PRIx32
        "\",\"observer_exit\":0}\n", (uint32_t)code, (uint32_t)code);
    result = 0;
close:
    if (!CloseHandle(process))
        return failure("CloseHandle", GetLastError(), 8);
    return result;
}
