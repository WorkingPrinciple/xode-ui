#define S3_KEY_TEST
#define main key_main
#include "key-audited-v1.c"
#undef main
#include <assert.h>

static const char *scenario;
static int sleeps, sends;
static unsigned long long ticks;
static HWND primary = (HWND)(intptr_t)1;

static int mode(const char *name) { return !strcmp(scenario, name); }
BOOL IsWindow(HWND window) { return window != NULL; }
BOOL IsWindowVisible(HWND window) { return window != NULL && !mode("hidden"); }
int GetWindowTextLengthA(HWND window) { (void)window; return 10; }
DWORD GetWindowThreadProcessId(HWND window, DWORD *pid)
{
    *pid = window == primary && !mode("wrong-pid") ? 220 : 221;
    return 1;
}
int GetWindowTextA(HWND window, char *buffer, int size)
{
    (void)window;
    const char *title = mode("wrong-title") || (mode("changed-title") && sleeps)
        ? "Other" : "Dishonored";
    snprintf(buffer, (size_t)size, "%s", title);
    return (int)strlen(buffer);
}
int GetClassNameA(HWND window, char *buffer, int size)
{
    (void)window;
    snprintf(buffer, (size_t)size, "%s",
        mode("wrong-class") ? "Other" : "LaunchUnrealUWindowsClient");
    return (int)strlen(buffer);
}
BOOL EnumWindows(BOOL (*callback)(HWND, LPARAM), LPARAM param)
{
    if (mode("enum-error")) return 0;
    callback(primary, param);
    if (mode("duplicate") || (mode("late-duplicate") && sleeps))
        callback((HWND)(intptr_t)2, param);
    return 1;
}
HWND GetForegroundWindow(void)
{
    return mode("foreground-denied") || (mode("lost-before-up") && sleeps >= 2) ||
        (mode("lost-after-up") && sends >= 2) ? (HWND)(intptr_t)2 : primary;
}
BOOL SetForegroundWindow(HWND window) { (void)window; return !mode("foreground-denied"); }
void Sleep(DWORD duration) { sleeps++; ticks += duration; }
UINT MapVirtualKeyA(UINT key, UINT mode_value)
{
    assert(mode_value == MAPVK_VK_TO_VSC_EX);
    return mode("no-scan") ? 0 : key == 37 ? 0xe04b : 0x11;
}
UINT SendInput(UINT count, INPUT *input, int size)
{
    assert(count == 1 && size == sizeof(INPUT));
    assert(input->type == INPUT_KEYBOARD);
    assert(input->ki.dwFlags & KEYEVENTF_SCANCODE);
    assert((input->ki.dwFlags & KEYEVENTF_KEYUP) == (sends ? KEYEVENTF_KEYUP : 0));
    if (mode("extended"))
        assert(input->ki.wScan == 0x4b && (input->ki.dwFlags & KEYEVENTF_EXTENDEDKEY));
    sends++;
    return (mode("down-failed") && sends == 1) ||
        (mode("up-failed") && sends == 2) ? 0 : 1;
}
DWORD GetLastError(void) { return 5; }
unsigned long long GetTickCount64(void) { return ticks; }

int main(int argc, char **argv)
{
    assert(argc == 4);
    scenario = argv[1];
    char *args[] = {"key", "220", "Dishonored", "LaunchUnrealUWindowsClient", "87", "100"};
    if (mode("extended")) args[4] = "37";
    if (mode("bad-pid")) args[1] = "0";
    if (mode("bad-key")) args[4] = "87junk";
    if (mode("mouse")) args[4] = "1";
    if (mode("bad-hold")) args[5] = "1001";
    if (mode("bad-title")) args[2] = "Dishonored\n";
    int result = key_main(6, args);
    assert(result == atoi(argv[2]));
    assert(sends == atoi(argv[3]));
    return 0;
}
