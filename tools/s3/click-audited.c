#include <windows.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static DWORD expected_pid;
static const char *expected_title;
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

static BOOL CALLBACK find_target(HWND window, LPARAM unused)
{
    (void)unused;
    DWORD pid = 0;
    char title[1024];
    GetWindowThreadProcessId(window, &pid);
    if (pid != expected_pid || !IsWindowVisible(window))
        return TRUE;
    int length = GetWindowTextLengthA(window);
    if (length <= 0 || length >= (int)sizeof(title))
        return TRUE;
    if (GetWindowTextA(window, title, sizeof(title)) &&
        strcmp(title, expected_title) == 0) {
        target = window;
        matches++;
    }
    return TRUE;
}

static int still_target(void)
{
    DWORD pid = 0;
    char title[1024];
    if (!IsWindow(target) || !IsWindowVisible(target))
        return 0;
    GetWindowThreadProcessId(target, &pid);
    return pid == expected_pid &&
        GetWindowTextA(target, title, sizeof(title)) &&
        strcmp(title, expected_title) == 0 &&
        GetForegroundWindow() == target;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    long pid, x, y;
    if (argc != 5 || !number(argv[1], 1, 2147483647, &pid) ||
        !argv[2][0] || strlen(argv[2]) >= 1024 ||
        !number(argv[3], -32768, 32767, &x) ||
        !number(argv[4], -32768, 32767, &y)) {
        fprintf(stderr, "usage: click WINDOWS_PID EXACT_TITLE SCREEN_X SCREEN_Y\n");
        return 2;
    }
    expected_pid = (DWORD)pid;
    expected_title = argv[2];
    EnumWindows(find_target, 0);
    RECT bounds;
    POINT point = {x, y};
    if (matches != 1 || !GetWindowRect(target, &bounds) ||
        !PtInRect(&bounds, point)) {
        fprintf(stderr, "refused: expected unique exact-PID title and point inside its bounds; matches=%u\n", matches);
        return 3;
    }
    printf("event=matched pid=%lu hwnd=%p bounds=%ld,%ld,%ld,%ld x=%ld y=%ld tick=%llu\n",
        expected_pid, target, bounds.left, bounds.top, bounds.right, bounds.bottom,
        x, y, GetTickCount64());
    SetForegroundWindow(target);
    Sleep(150);
    if (!still_target() || !SetCursorPos((int)x, (int)y)) {
        fprintf(stderr, "refused: target not foreground or cursor placement failed\n");
        return 4;
    }
    POINT actual;
    if (!GetCursorPos(&actual) || actual.x != x || actual.y != y ||
        !still_target()) {
        fprintf(stderr, "refused: cursor or target identity changed before send\n");
        return 4;
    }
    INPUT down = {0}, up = {0};
    down.type = up.type = INPUT_MOUSE;
    down.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
    up.mi.dwFlags = MOUSEEVENTF_LEFTUP;
    printf("event=pre-down pid=%lu tick=%llu\n", expected_pid, GetTickCount64());
    UINT sent = SendInput(1, &down, sizeof(down));
    DWORD down_error = sent == 1 ? 0 : GetLastError();
    printf("event=post-down count=%u error=%lu tick=%llu\n",
        sent, down_error, GetTickCount64());
    if (sent != 1)
        return 5;
    Sleep(100);
    UINT released = SendInput(1, &up, sizeof(up));
    DWORD up_error = released == 1 ? 0 : GetLastError();
    printf("event=post-up count=%u error=%lu tick=%llu target_alive=%d\n",
        released, up_error, GetTickCount64(), IsWindow(target) != 0);
    return released == 1 ? 0 : 6;
}
