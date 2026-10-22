#ifdef S3_KEY_TEST
#include "key-test-win32.h"
#else
#include <windows.h>
#endif
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static DWORD expected_pid;
static const char *expected_title, *expected_class;
static HWND target;
static unsigned int matches;

static int number(const char *text, long minimum, long maximum, long *value)
{
    char *end;
    errno = 0;
    long parsed = strtol(text, &end, 10);
    if (errno || end == text || *end || parsed < minimum || parsed > maximum)
        return 0;
    *value = parsed;
    return 1;
}

static int identity(HWND window, DWORD *pid, char *title, char *cls)
{
    if (!IsWindow(window) || !IsWindowVisible(window))
        return 0;
    int length = GetWindowTextLengthA(window);
    if (length <= 0 || length >= 1024 ||
        !GetWindowThreadProcessId(window, pid) ||
        !GetWindowTextA(window, title, 1024) ||
        !GetClassNameA(window, cls, 256))
        return 0;
    return 1;
}

static BOOL CALLBACK find_target(HWND window, LPARAM unused)
{
    (void)unused;
    DWORD pid = 0;
    char title[1024], cls[256];
    if (identity(window, &pid, title, cls) && !strcmp(title, expected_title)) {
        matches++;
        if (pid == expected_pid && !strcmp(cls, expected_class))
            target = window;
    }
    return TRUE;
}

static int witness(const char *stage)
{
    HWND original = target;
    target = NULL;
    matches = 0;
    if (!EnumWindows(find_target, 0) || matches != 1 || target != original)
        return 0;
    HWND foreground = GetForegroundWindow();
    DWORD pid = 0;
    char title[1024], cls[256];
    if (!identity(foreground, &pid, title, cls))
        return 0;
    printf("event=%s hwnd=%p foreground=%p pid=%lu class=%s title=%s tick=%llu\n",
        stage, original, foreground, pid, cls, title, GetTickCount64());
    return foreground == original && pid == expected_pid &&
        !strcmp(title, expected_title) && !strcmp(cls, expected_class);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    long pid, key, hold;
    if (argc != 6 || !number(argv[1], 1, 2147483647, &pid) ||
        !argv[2][0] || strlen(argv[2]) >= 1024 ||
        !argv[3][0] || strlen(argv[3]) >= 256 ||
        strpbrk(argv[2], "\r\n\t") || strpbrk(argv[3], "\r\n\t") ||
        !number(argv[4], 8, 254, &key) || !number(argv[5], 1, 1000, &hold)) {
        fprintf(stderr, "usage: key WINDOWS_PID EXACT_TITLE EXACT_CLASS DECIMAL_VK HOLD_MS(1..1000)\n");
        return 2;
    }
    expected_pid = (DWORD)pid;
    expected_title = argv[2];
    expected_class = argv[3];
    target = NULL;
    matches = 0;
    if (!EnumWindows(find_target, 0) || matches != 1 || !target) {
        fprintf(stderr, "refused: unique exact title/PID/class required; matches=%u\n", matches);
        return 3;
    }
    UINT scan = MapVirtualKeyA((UINT)key, MAPVK_VK_TO_VSC_EX);
    if (!scan || (scan >> 8 && scan >> 8 != 0xe0)) {
        fprintf(stderr, "refused: unsupported scan code\n");
        return 2;
    }
    INPUT down = {0}, up;
    down.type = INPUT_KEYBOARD;
    down.ki.wScan = (WORD)(scan & 0xff);
    down.ki.dwFlags = KEYEVENTF_SCANCODE |
        ((scan >> 8) == 0xe0 ? KEYEVENTF_EXTENDEDKEY : 0);
    up = down;
    up.ki.dwFlags |= KEYEVENTF_KEYUP;
    SetForegroundWindow(target);
    Sleep(150);
    if (!witness("pre-down")) {
        fprintf(stderr, "refused: foreground/identity changed before down\n");
        return 4;
    }
    UINT sent = SendInput(1, &down, sizeof(down));
    DWORD error = sent == 1 ? 0 : GetLastError();
    printf("event=post-down key=%ld hold_ms=%ld count=%u error=%lu tick=%llu\n",
        key, hold, sent, error, GetTickCount64());
    if (sent != 1)
        return 5;
    Sleep((DWORD)hold);
    if (!witness("pre-up")) {
        fprintf(stderr, "refused: foreground/identity changed before up; key release NOT delivered\n");
        return 6;
    }
    UINT released = SendInput(1, &up, sizeof(up));
    error = released == 1 ? 0 : GetLastError();
    printf("event=post-up key=%ld count=%u error=%lu tick=%llu\n",
        key, released, error, GetTickCount64());
    if (released != 1)
        return 7;
    if (!witness("post-up")) {
        fprintf(stderr, "refused: foreground/identity changed after up\n");
        return 8;
    }
    return 0;
}
