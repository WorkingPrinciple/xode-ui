#include <windows.h>
#include <stdio.h>

static int down_count;
static int up_count;
static ULONGLONG down_tick;
static ULONGLONG up_tick;

static LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_LBUTTONDOWN) {
        down_count++;
        down_tick = GetTickCount64();
        printf("receiver=down count=%d tick=%llu\n", down_count, down_tick);
        return 0;
    }
    if (message == WM_LBUTTONUP) {
        up_count++;
        up_tick = GetTickCount64();
        printf("receiver=up count=%d tick=%llu\n", up_count, up_tick);
        DestroyWindow(window);
        return 0;
    }
    if (message == WM_TIMER) {
        printf("receiver=timeout\n");
        DestroyWindow(window);
        return 0;
    }
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(window, message, wparam, lparam);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    HINSTANCE instance = GetModuleHandleA(NULL);
    WNDCLASSA cls = {0};
    cls.lpfnWndProc = procedure;
    cls.hInstance = instance;
    cls.lpszClassName = "S3ClickReceiver";
    if (!RegisterClassA(&cls)) {
        fprintf(stderr, "receiver=class-failed error=%lu\n", GetLastError());
        return 2;
    }
    HWND window = CreateWindowA(cls.lpszClassName, "S3 Click Receiver",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, 400, 300, 500, 300,
        NULL, NULL, instance, NULL);
    if (!window) {
        fprintf(stderr, "receiver=window-failed error=%lu\n", GetLastError());
        return 3;
    }
    if (!SetTimer(window, 1, 25000, NULL)) {
        fprintf(stderr, "receiver=timer-failed error=%lu\n", GetLastError());
        DestroyWindow(window);
        return 4;
    }
    RECT client;
    POINT point;
    if (!GetClientRect(window, &client)) {
        fprintf(stderr, "receiver=client-failed\n");
        DestroyWindow(window);
        return 5;
    }
    point.x = (client.left + client.right) / 2;
    point.y = (client.top + client.bottom) / 2;
    if (!ClientToScreen(window, &point)) {
        fprintf(stderr, "receiver=position-failed\n");
        DestroyWindow(window);
        return 5;
    }
    printf("receiver=ready pid=%lu window=%p x=%ld y=%ld\n",
        GetCurrentProcessId(), window, point.x, point.y);
    MSG message;
    int result;
    while ((result = GetMessageA(&message, NULL, 0, 0)) > 0) {
        TranslateMessage(&message);
        DispatchMessageA(&message);
    }
    printf("receiver=finished down=%d up=%d hold_ms=%llu message_result=%d\n",
        down_count, up_count, up_tick >= down_tick ? up_tick - down_tick : 0, result);
    return result == 0 && down_count == 1 && up_count == 1 &&
        up_tick >= down_tick && up_tick - down_tick >= 75 &&
        up_tick - down_tick <= 500 ? 0 : 1;
}
